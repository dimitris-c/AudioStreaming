#include "include/VorbisFileBridge.h"

#include <stdlib.h>
#include <string.h>
#include <vorbis/vorbisfile.h>

#include "OggRingBuffer.h"

// The ring buffer lives in OggRingBuffer.c, shared with OpusFileBridge.c.
// These wrappers keep the VF* API surface the Swift layer expects.

VFStreamRef VFStreamCreate(size_t capacity_bytes) {
    return (VFStreamRef)ogg_rb_create(capacity_bytes);
}

void VFStreamDestroy(VFStreamRef sr) {
    ogg_rb_destroy((struct OggRingBuffer *)sr);
}

size_t VFStreamAvailableBytes(VFStreamRef sr) {
    return ogg_rb_available((struct OggRingBuffer *)sr);
}

void VFStreamPush(VFStreamRef sr, const uint8_t *data, size_t len) {
    ogg_rb_push((struct OggRingBuffer *)sr, data, len);
}

void VFStreamMarkEOF(VFStreamRef sr) {
    ogg_rb_mark_eof((struct OggRingBuffer *)sr);
}

// libvorbisfile callbacks

// Read callback for libvorbisfile
static size_t read_cb(void *ptr, size_t size, size_t nmemb, void *datasrc) {
    if (!datasrc || size == 0) return 0;
    // Read what's available NOW - don't block waiting for more data. Returning
    // 0 signals EOF to libvorbisfile.
    size_t got = ogg_rb_take((struct OggRingBuffer *)datasrc, (uint8_t *)ptr, size * nmemb);
    return got / size;
}

// Seek callback - seek within the ring buffer
static int seek_cb(void *datasrc, ogg_int64_t offset, int whence) {
    struct OggRingBuffer *s = (struct OggRingBuffer *)datasrc;
    if (!s) return -1;
    
    pthread_mutex_lock(&s->m);
    
    ogg_int64_t new_pos = 0;
    switch (whence) {
        case SEEK_SET:
            new_pos = offset;
            break;
        case SEEK_CUR:
            new_pos = s->pos + offset;
            break;
        case SEEK_END:
            new_pos = s->total_pushed + offset;
            break;
        default:
            pthread_mutex_unlock(&s->m);
            return -1;
    }
    
    // Check if the new position is valid (within available data)
    if (new_pos < 0 || new_pos > s->total_pushed) {
        pthread_mutex_unlock(&s->m);
        return -1; // Can't seek outside available data
    }
    
    // Calculate how much data we've already consumed from the buffer
    long long already_consumed = s->pos - ((long long)s->total_pushed - (long long)s->size);
    
    // Calculate the new head position
    long long pos_delta = new_pos - s->pos;
    
    // For forward seeks, we need to have enough data in the buffer
    if (pos_delta > 0 && pos_delta > (long long)s->size) {
        pthread_mutex_unlock(&s->m);
        return -1; // Not enough data in buffer to seek forward
    }
    
    // For backward seeks, check if that data is still in the buffer
    if (pos_delta < 0 && (-pos_delta) > already_consumed) {
        pthread_mutex_unlock(&s->m);
        return -1; // Data has been discarded from buffer
    }
    
    // Adjust head pointer
    if (pos_delta >= 0) {
        // Forward seek: advance head
        s->head = (s->head + pos_delta) % s->cap;
        s->size -= (size_t)pos_delta;
    } else {
        // Backward seek: rewind head
        size_t rewind = (size_t)(-pos_delta);
        if (s->head >= rewind) {
            s->head -= rewind;
        } else {
            s->head = s->cap - (rewind - s->head);
        }
        s->size += rewind;
    }
    
    s->pos = new_pos;
    pthread_mutex_unlock(&s->m);
    return 0;
}

// Close callback - no-op
static int close_cb(void *datasrc) {
    (void)datasrc;
    return 0;
}

// Tell callback - return current position
static long tell_cb(void *datasrc) {
    struct OggRingBuffer *s = (struct OggRingBuffer *)datasrc;
    return (long)s->pos;
}

// Open a vorbis file using callbacks
int VFOpen(VFStreamRef sr, VFFileRef *out_vf) {
    struct OggRingBuffer *s = (struct OggRingBuffer *)sr;
    if (!s || !out_vf) return -1;
    
    OggVorbis_File *vf = (OggVorbis_File *)malloc(sizeof(OggVorbis_File));
    if (!vf) return -1;
    
    ov_callbacks cbs;
    cbs.read_func = read_cb;
    cbs.seek_func = NULL; // Non-seekable streaming (seeking handled at Swift level)
    cbs.close_func = close_cb;
    cbs.tell_func = tell_cb;
    
    int rc = ov_open_callbacks((void *)s, vf, NULL, 0, cbs);
    if (rc < 0) { free(vf); return rc; }
    
    *out_vf = (VFFileRef)vf;
    return 0;
}

// Clear a vorbis file
void VFClear(VFFileRef fr) {
    OggVorbis_File *vf = (OggVorbis_File *)fr;
    if (!vf) return;
    ov_clear(vf);
    free(vf);
}

// Get stream info
int VFGetInfo(VFFileRef fr, VFStreamInfo *out_info) {
    OggVorbis_File *vf = (OggVorbis_File *)fr;
    if (!vf || !out_info) return -1;
    
    vorbis_info const *info = ov_info(vf, -1);
    if (!info) return -1;
    
    out_info->sample_rate = info->rate;
    out_info->channels = info->channels;
    out_info->total_pcm_samples = ov_pcm_total(vf, -1);
    out_info->duration_seconds = ov_time_total(vf, -1);
    out_info->bitrate_nominal = info->bitrate_nominal;
    
    return 0;
}

// Read deinterleaved float PCM frames
long VFReadFloat(VFFileRef fr, float ***out_pcm, int max_frames) {
    OggVorbis_File *vf = (OggVorbis_File *)fr;
    if (!vf || !out_pcm || max_frames <= 0) return -1;
    
    int bitstream = 0;
    long frames = ov_read_float(vf, out_pcm, max_frames, &bitstream);
    
    // Returns: frames read (0 = EOF, <0 = error)
    return frames;
}

// Read interleaved float PCM frames (legacy, less efficient)
long VFReadInterleavedFloat(VFFileRef fr, float *dst, int max_frames) {
    OggVorbis_File *vf = (OggVorbis_File *)fr;
    if (!vf || !dst || max_frames <= 0) return -1;
    
    int bitstream = 0;
    float **pcm = NULL;
    long frames = ov_read_float(vf, &pcm, max_frames, &bitstream);
    
    if (frames <= 0) return frames; // 0 EOF, <0 error/hole
    
    vorbis_info const *info = ov_info(vf, -1);
    int ch = info->channels;
    
    // Interleave the PCM data
    for (long f = 0; f < frames; ++f) {
        for (int c = 0; c < ch; ++c) {
            dst[f * ch + c] = pcm[c][f];
        }
    }
    
    return frames;
}

// Seek to a specific time in seconds
int VFSeekTime(VFFileRef fr, double time_seconds) {
    OggVorbis_File *vf = (OggVorbis_File *)fr;
    if (!vf) return -1;
    
    // Use ov_time_seek for time-based seeking
    // Returns 0 on success, nonzero on failure
    return ov_time_seek(vf, time_seconds);
}

// Check if the stream is seekable
int VFIsSeekable(VFFileRef fr) {
    OggVorbis_File *vf = (OggVorbis_File *)fr;
    if (!vf) return 0;
    
    // Returns nonzero if the stream is seekable
    return ov_seekable(vf);
}
