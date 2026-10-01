#ifndef OPUS_FILE_BRIDGE_H
#define OPUS_FILE_BRIDGE_H

#include <stddef.h>
#include <stdint.h>

// Opaque refs for Swift-friendly API.
// Mirrors VorbisFileBridge.h so OggStreamProcessor can drive either decoder.
typedef void * OFStreamRef;
typedef void * OFFileRef;

#ifdef __cplusplus
extern "C" {
#endif

// Stream info structure
typedef struct {
    int sample_rate;             // Always 48000 for Opus (opusfile always outputs 48 kHz)
    int channels;
    long long total_pcm_samples; // -1 if unknown (non-seekable stream)
    double duration_seconds;     // < 0 if unknown
    long bitrate_nominal;        // instantaneous bitrate in bits/sec, or 0 if unknown
} OFStreamInfo;

// Stream lifecycle
OFStreamRef OFStreamCreate(size_t capacity_bytes);
void OFStreamDestroy(OFStreamRef s);
size_t OFStreamAvailableBytes(OFStreamRef s);

// Feeding data
void OFStreamPush(OFStreamRef s, const uint8_t *data, size_t len);
void OFStreamMarkEOF(OFStreamRef s);

// Decoder lifecycle
// Returns 0 on success, negative on error (opusfile OP_* codes)
int OFOpen(OFStreamRef s, OFFileRef *out_of);
void OFClear(OFFileRef of);

// Query info; returns 0 on success
int OFGetInfo(OFFileRef of, OFStreamInfo *out_info);

// Read deinterleaved float32 PCM frames into caller-provided channel pointers.
// `dst` is an array of `channels` pointers, each with room for max_frames floats.
// Returns frames read per channel, 0 on EOF, <0 on error.
//
// NOTE: opusfile has no deinterleaved read (unlike ov_read_float), so this
// deinterleaves internally into the caller's buffers. Callers must not assume
// the returned data is owned by the decoder — it is written into `dst`.
long OFReadFloatDeinterleaved(OFFileRef of, float **dst, int max_frames, int channels);

// Read interleaved float32 PCM frames into dst (room for max_frames * channels floats).
// Returns frames read per channel, 0 on EOF, <0 on error.
long OFReadInterleavedFloat(OFFileRef of, float *dst, int max_frames, int channels);

// Seek to a specific time in seconds; returns 0 on success, <0 on error
int OFSeekTime(OFFileRef of, double time_seconds);

// Check if the stream is seekable; returns 1 if seekable, 0 if not
int OFIsSeekable(OFFileRef of);

#ifdef __cplusplus
}
#endif

#endif // OPUS_FILE_BRIDGE_H
