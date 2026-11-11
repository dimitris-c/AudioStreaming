#include "include/OpusFileBridge.h"

#include <stdlib.h>
#include <string.h>
#include <opus/opusfile.h>

#include "OggRingBuffer.h"

// Ring buffer + opusfile callback shim.
//
// Deliberately mirrors VorbisFileBridge.c so the two Ogg codecs behave
// identically from the Swift side. The only structural difference is the
// callback signatures: opusfile uses a byte-count read (op_read_func) rather
// than libvorbisfile's fread-style (size, nmemb) pair.

// The ring buffer lives in OggRingBuffer.c, shared with VorbisFileBridge.c.
// These wrappers keep the OF* API surface the Swift layer expects.

OFStreamRef OFStreamCreate(size_t capacity_bytes) {
    return (OFStreamRef)ogg_rb_create(capacity_bytes);
}

void OFStreamDestroy(OFStreamRef sr) {
    ogg_rb_destroy((struct OggRingBuffer *)sr);
}

size_t OFStreamAvailableBytes(OFStreamRef sr) {
    return ogg_rb_available((struct OggRingBuffer *)sr);
}

void OFStreamPush(OFStreamRef sr, const uint8_t *data, size_t len) {
    ogg_rb_push((struct OggRingBuffer *)sr, data, len);
}

void OFStreamMarkEOF(OFStreamRef sr) {
    ogg_rb_mark_eof((struct OggRingBuffer *)sr);
}

// A decoder handle: the opusfile object plus a scratch buffer.
//
// libopusfile offers only an interleaved read (there is no equivalent of
// libvorbisfile's ov_read_float), so producing deinterleaved output needs a
// staging buffer. Allocating it per read would put a malloc in the render
// path, so the handle owns it and grows it at most once per buffer size.
struct OFFile {
    OggOpusFile *of;
    float *scratch;
    size_t scratch_floats;
};

// Returns a scratch buffer of at least `floats_needed` floats, or NULL on
// allocation failure. Steady state performs no allocation.
static float *of_scratch(struct OFFile *f, size_t floats_needed) {
    if (f->scratch && f->scratch_floats >= floats_needed) return f->scratch;
    float *grown = (float *)realloc(f->scratch, floats_needed * sizeof(float));
    if (!grown) return NULL;
    f->scratch = grown;
    f->scratch_floats = floats_needed;
    return grown;
}

// MARK: - opusfile callbacks

// op_read_func: returns bytes read, 0 on EOF, <0 on error.
// Non-blocking: returns whatever is available now, exactly like the Vorbis shim.
static int read_cb(void *stream, unsigned char *ptr, int nbytes) {
    if (!stream || nbytes <= 0) return 0;
    // got == 0 with eof set signals EOF to opusfile; got == 0 without eof is a
    // short read, which opusfile also treats as end-of-stream. The Swift layer
    // gates calls on availableBytes() to avoid the latter.
    return (int)ogg_rb_take((struct OggRingBuffer *)stream, ptr, (size_t)nbytes);
}

static int close_cb(void *stream) {
    (void)stream;
    return 0;
}

static opus_int64 tell_cb(void *stream) {
    struct OggRingBuffer *s = (struct OggRingBuffer *)stream;
    if (!s) return -1;
    return (opus_int64)s->pos;
}

int OFOpen(OFStreamRef sr, OFFileRef *out_of) {
    struct OggRingBuffer *s = (struct OggRingBuffer *)sr;
    if (!s || !out_of) return -1;

    OpusFileCallbacks cbs;
    cbs.read  = read_cb;
    cbs.seek  = NULL;  // Non-seekable streaming (seeking handled at Swift level)
    cbs.tell  = tell_cb;
    cbs.close = close_cb;

    // A failed open is the normal case while the header is still arriving, so
    // it must not damage the stream. op_open_callbacks consumes bytes through
    // read_cb before it discovers the header is short, which advances the ring
    // buffer past data the next attempt still needs — without the rewind below
    // the retry sees a mid-stream position and every subsequent attempt fails
    // with OP_ENOTFORMAT, so the track never plays.
    //
    // read_cb is the only consumer and it advances s->pos by exactly the bytes
    // it took, so the delta is the amount to give back. Callers serialise open
    // against push (OpusFileDecoder holds decoderLock across both), so no
    // producer can have overwritten the reclaimed region.
    long long saved_pos = ogg_rb_position(s);

    int err = 0;
    OggOpusFile *of = op_open_callbacks((void *)s, &cbs, NULL, 0, &err);
    if (!of) {
        ogg_rb_rewind_to(s, saved_pos);
        return err != 0 ? err : -1;
    }

    struct OFFile *f = (struct OFFile *)calloc(1, sizeof(struct OFFile));
    if (!f) {
        op_free(of);
        return -1;
    }
    f->of = of;

    *out_of = (OFFileRef)f;
    return 0;
}

void OFClear(OFFileRef fr) {
    struct OFFile *f = (struct OFFile *)fr;
    if (!f) return;
    if (f->of) op_free(f->of);
    free(f->scratch);
    free(f);
}

int OFGetInfo(OFFileRef fr, OFStreamInfo *out_info) {
    struct OFFile *f = (struct OFFile *)fr;
    if (!f || !f->of || !out_info) return -1;
    OggOpusFile *of = f->of;

    const OpusHead *head = op_head(of, -1);
    if (!head) return -1;

    // opusfile always decodes to 48 kHz regardless of the original input rate.
    // head->input_sample_rate is informational only and must NOT be used as the
    // output rate — doing so is the classic Opus pitch-shift bug.
    out_info->sample_rate = 48000;
    out_info->channels = op_channel_count(of, -1);

    // op_pcm_total requires a seekable stream; HTTP sources report -1 here and
    // the Swift layer falls back to a bitrate-based duration estimate.
    opus_int64 total = op_pcm_total(of, -1);
    if (total >= 0) {
        out_info->total_pcm_samples = (long long)total;
        out_info->duration_seconds = (double)total / 48000.0;
    } else {
        out_info->total_pcm_samples = -1;
        out_info->duration_seconds = -1;
    }

    // op_bitrate() also requires a seekable stream. For live/HTTP sources fall
    // back to the instantaneous estimate, which is 0 until packets decode.
    opus_int32 br = op_bitrate(of, -1);
    if (br <= 0) br = op_bitrate_instant(of);
    out_info->bitrate_nominal = br > 0 ? (long)br : 0;

    return 0;
}

long OFReadInterleavedFloat(OFFileRef fr, float *dst, int max_frames, int channels) {
    struct OFFile *f = (struct OFFile *)fr;
    if (!f || !f->of || !dst || max_frames <= 0 || channels <= 0) return -1;

    // op_read_float takes the buffer size in TOTAL floats, not frames.
    int li = 0;
    int frames = op_read_float(f->of, dst, max_frames * channels, &li);
    if (frames < 0) return (long)frames;  // OP_* error code
    return (long)frames;                  // 0 == EOF
}

long OFReadFloatDeinterleaved(OFFileRef fr, float **dst, int max_frames, int channels) {
    struct OFFile *f = (struct OFFile *)fr;
    if (!f || !f->of || !dst || max_frames <= 0 || channels <= 0) return -1;

    float *scratch = of_scratch(f, (size_t)max_frames * (size_t)channels);
    if (!scratch) return -1;

    int li = 0;
    int frames = op_read_float(f->of, scratch, max_frames * channels, &li);
    if (frames <= 0) return (long)frames;

    // op_read_float reports the channel count of the link it just decoded; a
    // chained stream can change it mid-file. Deinterleave with the stride the
    // data actually has, not the one the caller asked for, or the output is
    // garbled rather than merely wrong-length.
    int decoded_channels = op_channel_count(f->of, li);
    if (decoded_channels <= 0) decoded_channels = channels;

    for (int c = 0; c < channels; ++c) {
        float *out = dst[c];
        if (!out) continue;
        if (c < decoded_channels) {
            for (int fr_i = 0; fr_i < frames; ++fr_i) {
                out[fr_i] = scratch[fr_i * decoded_channels + c];
            }
        } else {
            // Caller wants more channels than this link carries; silence the rest.
            for (int fr_i = 0; fr_i < frames; ++fr_i) out[fr_i] = 0.0f;
        }
    }

    return (long)frames;
}

int OFSeekTime(OFFileRef fr, double time_seconds) {
    struct OFFile *f = (struct OFFile *)fr;
    if (!f || !f->of) return -1;
    if (!op_seekable(f->of)) return -1;
    // opusfile seeks by sample position at the fixed 48 kHz output rate.
    opus_int64 target = (opus_int64)(time_seconds * 48000.0);
    return op_pcm_seek(f->of, target);
}

int OFIsSeekable(OFFileRef fr) {
    struct OFFile *f = (struct OFFile *)fr;
    if (!f || !f->of) return 0;
    return op_seekable(f->of);
}
