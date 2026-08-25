#include "include/OpusFileBridge.h"

#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <opus/opusfile.h>

// Ring buffer + opusfile callback shim.
//
// Deliberately mirrors VorbisFileBridge.c so the two Ogg codecs behave
// identically from the Swift side. The only structural difference is the
// callback signatures: opusfile uses a byte-count read (op_read_func) rather
// than libvorbisfile's fread-style (size, nmemb) pair.

struct OFRemoteStream {
    uint8_t *buf;
    size_t cap, head, tail, size;
    int eof;
    long long pos;           // Current read position in the stream
    long long total_pushed;  // Total bytes pushed into the buffer
    pthread_mutex_t m;
    pthread_cond_t cv;
};

static size_t rb_write(struct OFRemoteStream *s, const uint8_t *src, size_t len) {
    size_t written = 0;
    while (written < len) {
        size_t free_space = s->cap - s->size;
        if (free_space == 0) break;
        size_t chunk = s->cap - s->tail;
        if (chunk > len - written) chunk = len - written;
        if (chunk > free_space) chunk = free_space;
        memcpy(s->buf + s->tail, src + written, chunk);
        s->tail = (s->tail + chunk) % s->cap;
        s->size += chunk;
        written += chunk;
    }
    return written;
}

static size_t rb_read(struct OFRemoteStream *s, uint8_t *dst, size_t len) {
    size_t read = 0;
    while (read < len && s->size > 0) {
        size_t chunk = s->cap - s->head;
        if (chunk > s->size) chunk = s->size;
        if (chunk > len - read) chunk = len - read;
        memcpy(dst + read, s->buf + s->head, chunk);
        s->head = (s->head + chunk) % s->cap;
        s->size -= chunk;
        read += chunk;
    }
    return read;
}

OFStreamRef OFStreamCreate(size_t capacity_bytes) {
    struct OFRemoteStream *s = (struct OFRemoteStream *)calloc(1, sizeof(struct OFRemoteStream));
    if (!s) return NULL;
    s->buf = (uint8_t *)malloc(capacity_bytes);
    if (!s->buf) { free(s); return NULL; }
    s->cap = capacity_bytes;
    pthread_mutex_init(&s->m, NULL);
    pthread_cond_init(&s->cv, NULL);
    return s;
}

void OFStreamDestroy(OFStreamRef sr) {
    struct OFRemoteStream *s = (struct OFRemoteStream *)sr;
    if (!s) return;
    pthread_mutex_destroy(&s->m);
    pthread_cond_destroy(&s->cv);
    free(s->buf);
    free(s);
}

size_t OFStreamAvailableBytes(OFStreamRef sr) {
    struct OFRemoteStream *s = (struct OFRemoteStream *)sr;
    if (!s) return 0;
    pthread_mutex_lock(&s->m);
    size_t sz = s->size;
    pthread_mutex_unlock(&s->m);
    return sz;
}

void OFStreamPush(OFStreamRef sr, const uint8_t *data, size_t len) {
    struct OFRemoteStream *s = (struct OFRemoteStream *)sr;
    if (!s || !data || len == 0) return;

    pthread_mutex_lock(&s->m);
    size_t written_total = 0;
    while (written_total < len) {
        size_t w = rb_write(s, data + written_total, len - written_total);
        written_total += w;
        if (written_total < len) {
            // Buffer full, wait for consumer to read
            pthread_cond_wait(&s->cv, &s->m);
        }
    }
    s->total_pushed += (long long)len;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
}

void OFStreamMarkEOF(OFStreamRef sr) {
    struct OFRemoteStream *s = (struct OFRemoteStream *)sr;
    if (!s) return;
    pthread_mutex_lock(&s->m);
    s->eof = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
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
    struct OFRemoteStream *s = (struct OFRemoteStream *)stream;
    if (!s || nbytes <= 0) return 0;

    size_t want_bytes = (size_t)nbytes;
    size_t got = 0;

    pthread_mutex_lock(&s->m);
    while (got < want_bytes && s->size > 0) {
        size_t chunk = rb_read(s, ptr + got, want_bytes - got);
        if (chunk == 0) break;
        s->pos += (long long)chunk;
        got += chunk;
        pthread_cond_broadcast(&s->cv);
    }
    pthread_mutex_unlock(&s->m);

    // got == 0 with eof set signals EOF to opusfile; got == 0 without eof is a
    // short read, which opusfile also treats as end-of-stream. The Swift layer
    // gates calls on availableBytes() to avoid the latter.
    return (int)got;
}

static int close_cb(void *stream) {
    (void)stream;
    return 0;
}

static opus_int64 tell_cb(void *stream) {
    struct OFRemoteStream *s = (struct OFRemoteStream *)stream;
    if (!s) return -1;
    return (opus_int64)s->pos;
}

int OFOpen(OFStreamRef sr, OFFileRef *out_of) {
    struct OFRemoteStream *s = (struct OFRemoteStream *)sr;
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
    pthread_mutex_lock(&s->m);
    long long saved_pos = s->pos;
    pthread_mutex_unlock(&s->m);

    int err = 0;
    OggOpusFile *of = op_open_callbacks((void *)s, &cbs, NULL, 0, &err);
    if (!of) {
        pthread_mutex_lock(&s->m);
        long long consumed = s->pos - saved_pos;
        if (consumed > 0 && (size_t)consumed <= s->cap - s->size) {
            s->head = (s->head + s->cap - ((size_t)consumed % s->cap)) % s->cap;
            s->size += (size_t)consumed;
            s->pos = saved_pos;
        }
        pthread_cond_broadcast(&s->cv);
        pthread_mutex_unlock(&s->m);
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
