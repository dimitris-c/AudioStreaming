//
//  OggRingBuffer.c
//  AudioCodecs
//

#include "OggRingBuffer.h"

#include <stdlib.h>
#include <string.h>

size_t ogg_rb_write_locked(struct OggRingBuffer *s, const uint8_t *src, size_t len) {
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

size_t ogg_rb_read_locked(struct OggRingBuffer *s, uint8_t *dst, size_t len) {
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

struct OggRingBuffer *ogg_rb_create(size_t capacity_bytes) {
    struct OggRingBuffer *s = (struct OggRingBuffer *)calloc(1, sizeof(struct OggRingBuffer));
    if (!s) return NULL;
    s->buf = (uint8_t *)malloc(capacity_bytes);
    if (!s->buf) { free(s); return NULL; }
    s->cap = capacity_bytes;
    pthread_mutex_init(&s->m, NULL);
    pthread_cond_init(&s->cv, NULL);
    return s;
}

void ogg_rb_destroy(struct OggRingBuffer *s) {
    if (!s) return;
    pthread_mutex_destroy(&s->m);
    pthread_cond_destroy(&s->cv);
    free(s->buf);
    free(s);
}

size_t ogg_rb_available(struct OggRingBuffer *s) {
    if (!s) return 0;
    pthread_mutex_lock(&s->m);
    size_t sz = s->size;
    pthread_mutex_unlock(&s->m);
    return sz;
}

void ogg_rb_push(struct OggRingBuffer *s, const uint8_t *data, size_t len) {
    if (!s || !data || len == 0) return;

    pthread_mutex_lock(&s->m);
    size_t written_total = 0;
    while (written_total < len) {
        size_t w = ogg_rb_write_locked(s, data + written_total, len - written_total);
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

void ogg_rb_mark_eof(struct OggRingBuffer *s) {
    if (!s) return;
    pthread_mutex_lock(&s->m);
    s->eof = 1;
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
}

size_t ogg_rb_take(struct OggRingBuffer *s, uint8_t *dst, size_t len) {
    if (!s || !dst || len == 0) return 0;

    size_t got = 0;
    pthread_mutex_lock(&s->m);
    // Read what's available NOW - don't block waiting for more data.
    while (got < len && s->size > 0) {
        size_t chunk = ogg_rb_read_locked(s, dst + got, len - got);
        if (chunk == 0) break;
        s->pos += (long long)chunk;
        got += chunk;
        // Allow producer to push more
        pthread_cond_broadcast(&s->cv);
    }
    pthread_mutex_unlock(&s->m);
    return got;
}

long long ogg_rb_position(struct OggRingBuffer *s) {
    if (!s) return -1;
    pthread_mutex_lock(&s->m);
    long long p = s->pos;
    pthread_mutex_unlock(&s->m);
    return p;
}

int ogg_rb_rewind_to(struct OggRingBuffer *s, long long saved_pos) {
    if (!s) return 0;
    int ok = 0;
    pthread_mutex_lock(&s->m);
    long long consumed = s->pos - saved_pos;
    if (consumed > 0 && (size_t)consumed <= s->cap - s->size) {
        s->head = (s->head + s->cap - ((size_t)consumed % s->cap)) % s->cap;
        s->size += (size_t)consumed;
        s->pos = saved_pos;
        ok = 1;
    }
    pthread_cond_broadcast(&s->cv);
    pthread_mutex_unlock(&s->m);
    return ok;
}
