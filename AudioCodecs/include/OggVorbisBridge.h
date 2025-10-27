//
//  OggVorbisBridge.h
//  AudioStreaming
//
//  Created on 25/10/2025.
//

#ifndef OggVorbisBridge_h
#define OggVorbisBridge_h

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <ogg/ogg.h>
#include <vorbis/codec.h>
#include <vorbis/vorbisfile.h>

// Error codes
typedef enum {
    OGGVORBIS_SUCCESS = 0,
    OGGVORBIS_ERROR_OUT_OF_MEMORY = -1,
    OGGVORBIS_ERROR_INVALID_SETUP = -2,
    OGGVORBIS_ERROR_INVALID_STREAM = -3,
    OGGVORBIS_ERROR_INVALID_HEADER = -4,
    OGGVORBIS_ERROR_INVALID_PACKET = -5,
    OGGVORBIS_ERROR_INTERNAL = -6,
    OGGVORBIS_ERROR_EOF = -7
} OggVorbisError;

// Stream info
typedef struct {
    uint32_t serialNumber;
    uint64_t pageCount;
    uint64_t totalSamples;
    uint32_t sampleRate;
    uint8_t channels;
    uint32_t bitRate;
    uint32_t nominalBitrate;
    uint32_t minBitrate;
    uint32_t maxBitrate;
    int blocksize0;
    int blocksize1;
    int64_t granulePosition;
} OggVorbisStreamInfo;

// Decoder context
typedef struct OggVorbisDecoderContext OggVorbisDecoderContext;

// Create a new decoder context
OggVorbisDecoderContext* OggVorbisDecoderCreate(void);

// Destroy a decoder context
void OggVorbisDecoderDestroy(OggVorbisDecoderContext* context);

// Initialize the decoder with initial data
OggVorbisError OggVorbisDecoderInit(OggVorbisDecoderContext* context, const void* data, size_t dataSize);

// Process a chunk of Ogg Vorbis data
OggVorbisError OggVorbisDecoderProcessData(OggVorbisDecoderContext* context, const void* data, size_t dataSize);

// Get information about the Ogg Vorbis stream
OggVorbisError OggVorbisDecoderGetInfo(OggVorbisDecoderContext* context, OggVorbisStreamInfo* info);

// Get decoded PCM data
OggVorbisError OggVorbisDecoderGetPCMData(OggVorbisDecoderContext* context, float** pcmData, int* samplesDecoded);

// Seek to a specific time position (in seconds)
OggVorbisError OggVorbisDecoderSeek(OggVorbisDecoderContext* context, double timeInSeconds);

// Reset the decoder
OggVorbisError OggVorbisDecoderReset(OggVorbisDecoderContext* context);

// Get a comment from the Vorbis stream
const char* OggVorbisDecoderGetComment(OggVorbisDecoderContext* context, const char* key);

// Get all comments from the Vorbis stream
int OggVorbisDecoderGetCommentCount(OggVorbisDecoderContext* context);
void OggVorbisDecoderGetCommentPair(OggVorbisDecoderContext* context, int index, const char** key, const char** value);

#endif /* OggVorbisBridge_h */
