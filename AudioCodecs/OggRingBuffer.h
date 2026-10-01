//
//  OggRingBuffer.h
//  AudioCodecs
//
//  Shared blocking ring buffer for the Ogg codec bridges.
//
//  Both libvorbisfile and libopusfile are pull-based: they call a read callback
//  when they want bytes. The streaming layer is push-based. This buffer bridges
//  the two, blocking the producer when it fills and handing the consumer
//  whatever is available without blocking.
//
//  Internal to the AudioCodecs target — not part of the public umbrella header.
//

#ifndef OGG_RING_BUFFER_H
#define OGG_RING_BUFFER_H

#include <pthread.h>
#include <stddef.h>
#include <stdint.h>

// Fields are exposed rather than opaque because the codec bridges' seek
// callbacks reposition the buffer directly.
struct OggRingBuffer {
    uint8_t *buf;
    size_t cap, head, tail, size;
    int eof;
    long long pos;           // Current read position in the stream
    long long total_pushed;  // Total bytes pushed into the buffer
    pthread_mutex_t m;
    pthread_cond_t cv;
};

struct OggRingBuffer *ogg_rb_create(size_t capacity_bytes);
void ogg_rb_destroy(struct OggRingBuffer *s);

// Bytes currently buffered.
size_t ogg_rb_available(struct OggRingBuffer *s);

// Appends `len` bytes, blocking while the buffer is full.
void ogg_rb_push(struct OggRingBuffer *s, const uint8_t *data, size_t len);

void ogg_rb_mark_eof(struct OggRingBuffer *s);

// Consumes up to `len` bytes into `dst` and advances the stream position.
// Returns what was available now; does not wait for more.
size_t ogg_rb_take(struct OggRingBuffer *s, uint8_t *dst, size_t len);

// Current stream position, for callers that need to rewind later.
long long ogg_rb_position(struct OggRingBuffer *s);

// Returns the buffer to `saved_pos`, undoing consumption since that point.
// Only valid while no producer has overwritten the reclaimed region.
// Returns 1 if the rewind happened, 0 if it was not safe.
int ogg_rb_rewind_to(struct OggRingBuffer *s, long long saved_pos);

// Unlocked primitives, for callers already holding the lock.
size_t ogg_rb_write_locked(struct OggRingBuffer *s, const uint8_t *src, size_t len);
size_t ogg_rb_read_locked(struct OggRingBuffer *s, uint8_t *dst, size_t len);

#endif // OGG_RING_BUFFER_H
