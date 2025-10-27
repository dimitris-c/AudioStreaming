//
//  OggVorbisBridge.c
//  AudioStreaming
//
//  Created on 25/10/2025.
//

#include "include/OggVorbisBridge.h"

// Define the decoder context structure
struct OggVorbisDecoderContext {
    ogg_sync_state   oy;             // Ogg sync state
    ogg_stream_state os;             // Ogg stream state
    ogg_page         og;             // Ogg page
    ogg_packet       op;             // Ogg packet
    
    vorbis_info      vi;             // Vorbis info
    vorbis_comment   vc;             // Vorbis comment
    vorbis_dsp_state vd;             // Vorbis DSP state
    vorbis_block     vb;             // Vorbis block
    
    int              initialized;     // Whether the decoder is initialized
    int              headersParsed;   // Number of headers parsed (0-3)
    int              streamInitialized; // Whether the stream is initialized
    
    int64_t          granulePosition; // Current granule position
    int64_t          totalSamples;    // Total samples in stream
    int64_t          currentSample;   // Current sample position
    
    float**          pcmOutput;       // PCM output buffer
    int              pcmSamples;      // Number of PCM samples available
    int              pcmChannels;     // Number of PCM channels
    
    char**           commentKeys;     // Comment keys
    char**           commentValues;   // Comment values
    int              commentCount;    // Number of comments
};

// Create a new decoder context
OggVorbisDecoderContext* OggVorbisDecoderCreate(void) {
    OggVorbisDecoderContext* context = (OggVorbisDecoderContext*)malloc(sizeof(OggVorbisDecoderContext));
    if (context == NULL) {
        return NULL;
    }
    
    memset(context, 0, sizeof(OggVorbisDecoderContext));
    
    // Initialize Ogg sync state
    ogg_sync_init(&context->oy);
    
    // Initialize Vorbis structures
    vorbis_info_init(&context->vi);
    vorbis_comment_init(&context->vc);
    
    context->initialized = 0;
    context->headersParsed = 0;
    context->streamInitialized = 0;
    
    context->granulePosition = 0;
    context->totalSamples = 0;
    context->currentSample = 0;
    
    context->pcmOutput = NULL;
    context->pcmSamples = 0;
    context->pcmChannels = 0;
    
    context->commentKeys = NULL;
    context->commentValues = NULL;
    context->commentCount = 0;
    
    return context;
}

// Destroy a decoder context
void OggVorbisDecoderDestroy(OggVorbisDecoderContext* context) {
    if (context == NULL) {
        return;
    }
    
    // Clean up Vorbis structures
    if (context->initialized) {
        vorbis_block_clear(&context->vb);
        vorbis_dsp_clear(&context->vd);
    }
    
    vorbis_comment_clear(&context->vc);
    vorbis_info_clear(&context->vi);
    
    // Clean up Ogg structures
    if (context->streamInitialized) {
        ogg_stream_clear(&context->os);
    }
    ogg_sync_clear(&context->oy);
    
    // Free comment storage
    if (context->commentKeys != NULL) {
        for (int i = 0; i < context->commentCount; i++) {
            if (context->commentKeys[i] != NULL) {
                free(context->commentKeys[i]);
            }
            if (context->commentValues[i] != NULL) {
                free(context->commentValues[i]);
            }
        }
        free(context->commentKeys);
        free(context->commentValues);
    }
    
    free(context);
}

// Process Ogg pages and extract Vorbis headers
static OggVorbisError processOggPage(OggVorbisDecoderContext* context) {
    // Submit the page to the stream
    if (context->streamInitialized) {
        if (ogg_stream_pagein(&context->os, &context->og) < 0) {
            printf("OggVorbis: Error in ogg_stream_pagein for initialized stream\n");
            return OGGVORBIS_ERROR_INVALID_STREAM;
        }
    } else {
        // Get the serial number from the first page
        int serialno = ogg_page_serialno(&context->og);
        printf("OggVorbis: Initializing stream with serial number %d\n", serialno);
        ogg_stream_init(&context->os, serialno);
        context->streamInitialized = 1;
        
        if (ogg_stream_pagein(&context->os, &context->og) < 0) {
            printf("OggVorbis: Error in ogg_stream_pagein for new stream\n");
            return OGGVORBIS_ERROR_INVALID_STREAM;
        }
    }
    
    // Process all packets in the page
    while (ogg_stream_packetout(&context->os, &context->op) == 1) {
        // If we haven't parsed all headers yet
        if (context->headersParsed < 3) {
            printf("OggVorbis: Processing header packet %d, size %ld\n", context->headersParsed + 1, context->op.bytes);
            int result = vorbis_synthesis_headerin(&context->vi, &context->vc, &context->op);
            if (result < 0) {
                printf("OggVorbis: Error in vorbis_synthesis_headerin: %d\n", result);
                return OGGVORBIS_ERROR_INVALID_HEADER;
            }
            
            context->headersParsed++;
            printf("OggVorbis: Successfully parsed header %d\n", context->headersParsed);
            
            // After parsing all headers, initialize the synthesis
            if (context->headersParsed == 3) {
                printf("OggVorbis: All headers parsed, initializing synthesis\n");
                if (vorbis_synthesis_init(&context->vd, &context->vi) != 0) {
                    printf("OggVorbis: Error in vorbis_synthesis_init\n");
                    return OGGVORBIS_ERROR_INVALID_SETUP;
                }
                
                vorbis_block_init(&context->vd, &context->vb);
                context->initialized = 1;
                
                // Process comments
                context->commentCount = context->vc.comments;
                if (context->commentCount > 0) {
                    context->commentKeys = (char**)malloc(context->commentCount * sizeof(char*));
                    context->commentValues = (char**)malloc(context->commentCount * sizeof(char*));
                    
                    if (context->commentKeys == NULL || context->commentValues == NULL) {
                        return OGGVORBIS_ERROR_OUT_OF_MEMORY;
                    }
                    
                    for (int i = 0; i < context->commentCount; i++) {
                        char* comment = context->vc.user_comments[i];
                        char* equals = strchr(comment, '=');
                        
                        if (equals) {
                            size_t keyLen = (size_t)(equals - comment);
                            size_t valueLen = strlen(equals + 1);
                            
                            context->commentKeys[i] = (char*)malloc(keyLen + 1);
                            context->commentValues[i] = (char*)malloc(valueLen + 1);
                            
                            if (context->commentKeys[i] == NULL || context->commentValues[i] == NULL) {
                                return OGGVORBIS_ERROR_OUT_OF_MEMORY;
                            }
                            
                            strncpy(context->commentKeys[i], comment, keyLen);
                            context->commentKeys[i][keyLen] = '\0';
                            
                            strcpy(context->commentValues[i], equals + 1);
                        } else {
                            // No equals sign, use empty key
                            context->commentKeys[i] = (char*)malloc(1);
                            context->commentValues[i] = (char*)malloc(strlen(comment) + 1);
                            
                            if (context->commentKeys[i] == NULL || context->commentValues[i] == NULL) {
                                return OGGVORBIS_ERROR_OUT_OF_MEMORY;
                            }
                            
                            context->commentKeys[i][0] = '\0';
                            strcpy(context->commentValues[i], comment);
                        }
                    }
                }
            }
        } else {
            // Audio data packet
            int synthResult = vorbis_synthesis(&context->vb, &context->op);
            if (synthResult != 0) {
                printf("OggVorbis: Warning - skipping invalid packet (vorbis_synthesis returned %d)\n", synthResult);
                continue; // Skip this packet and continue with the next one
            }
            
            int blockinResult = vorbis_synthesis_blockin(&context->vd, &context->vb);
            if (blockinResult != 0) {
                printf("OggVorbis: Error in vorbis_synthesis_blockin: %d\n", blockinResult);
                return OGGVORBIS_ERROR_INTERNAL;
            }
            
            // Update granule position
            if (context->op.granulepos >= 0) {
                context->granulePosition = context->op.granulepos;
                if (context->granulePosition > context->totalSamples) {
                    context->totalSamples = context->granulePosition;
                }
            }
            
            // Extract PCM data
            float** pcm;
            int samples = vorbis_synthesis_pcmout(&context->vd, &pcm);
            
            if (samples > 0) {
                context->pcmOutput = pcm;
                context->pcmSamples = samples;
                context->pcmChannels = context->vi.channels;
                context->currentSample += samples;
                
                // Tell the decoder we've used these samples
                // IMPORTANT: Only mark as read if we're actually going to use the samples
                vorbis_synthesis_read(&context->vd, samples);
            }
        }
    }
    
    return OGGVORBIS_SUCCESS;
}

// Initialize the decoder with initial data
OggVorbisError OggVorbisDecoderInit(OggVorbisDecoderContext* context, const void* data, size_t dataSize) {
    if (context == NULL || data == NULL || dataSize == 0) {
        printf("OggVorbis: Invalid setup parameters in OggVorbisDecoderInit\n");
        return OGGVORBIS_ERROR_INVALID_SETUP;
    }
    
    printf("OggVorbis: Initializing with %zu bytes of data\n", dataSize);
    
    // Only reset the decoder if we haven't started parsing headers yet
    if (context->headersParsed == 0) {
        OggVorbisDecoderReset(context);
    }
    
    // Submit data to the sync layer
    char* buffer = ogg_sync_buffer(&context->oy, (long)dataSize);
    if (buffer == NULL) {
        printf("OggVorbis: Out of memory in ogg_sync_buffer\n");
        return OGGVORBIS_ERROR_OUT_OF_MEMORY;
    }
    
    memcpy(buffer, data, dataSize);
    ogg_sync_wrote(&context->oy, (long)dataSize);
    
    // Try to get a page
    int pageCount = 0;
    int pageOutResult;
    while ((pageOutResult = ogg_sync_pageout(&context->oy, &context->og)) == 1) {
        pageCount++;
        printf("OggVorbis: Found page %d, size %ld\n", pageCount, context->og.header_len + context->og.body_len);
        
        OggVorbisError result = processOggPage(context);
        if (result != OGGVORBIS_SUCCESS) {
            printf("OggVorbis: Error processing page %d: %d\n", pageCount, result);
            return result;
        }
        
        // If we've parsed all headers, we're done with initialization
        if (context->headersParsed == 3) {
            printf("OggVorbis: Successfully initialized with %d pages\n", pageCount);
            return OGGVORBIS_SUCCESS;
        }
    }
    
    if (pageOutResult == 0) {
        printf("OggVorbis: Need more data, only found %d pages, parsed %d headers\n", 
               pageCount, context->headersParsed);
    } else {
        printf("OggVorbis: Error in ogg_sync_pageout: %d\n", pageOutResult);
    }
    
    // If we get here, we didn't find all the headers
    printf("OggVorbis: Failed to find all headers (found %d of 3)\n", context->headersParsed);
    return OGGVORBIS_ERROR_INVALID_HEADER;
}

// Process a chunk of Ogg Vorbis data
OggVorbisError OggVorbisDecoderProcessData(OggVorbisDecoderContext* context, const void* data, size_t dataSize) {
    if (context == NULL || data == NULL || dataSize == 0) {
        return OGGVORBIS_ERROR_INVALID_SETUP;
    }
    
    // Reset PCM output
    context->pcmOutput = NULL;
    context->pcmSamples = 0;
    context->pcmChannels = 0;
    
    // Submit data to the sync layer
    char* buffer = ogg_sync_buffer(&context->oy, (long)dataSize);
    if (buffer == NULL) {
        return OGGVORBIS_ERROR_OUT_OF_MEMORY;
    }
    
    memcpy(buffer, data, dataSize);
    ogg_sync_wrote(&context->oy, (long)dataSize);
    
    // Process all pages
    while (ogg_sync_pageout(&context->oy, &context->og) == 1) {
        OggVorbisError result = processOggPage(context);
        if (result != OGGVORBIS_SUCCESS) {
            return result;
        }
    }
    
    return OGGVORBIS_SUCCESS;
}

// Get information about the Ogg Vorbis stream
OggVorbisError OggVorbisDecoderGetInfo(OggVorbisDecoderContext* context, OggVorbisStreamInfo* info) {
    if (context == NULL || info == NULL || !context->initialized) {
        return OGGVORBIS_ERROR_INVALID_SETUP;
    }
    
    info->serialNumber = (uint32_t)context->os.serialno;
    info->pageCount = 0; // Not tracked
    info->totalSamples = context->totalSamples;
    info->sampleRate = (uint32_t)context->vi.rate;
    info->channels = (uint8_t)context->vi.channels;
    info->bitRate = (uint32_t)(context->vi.bitrate_nominal / 1000);
    info->nominalBitrate = (uint32_t)(context->vi.bitrate_nominal / 1000);
    info->minBitrate = (uint32_t)(context->vi.bitrate_lower / 1000);
    info->maxBitrate = (uint32_t)(context->vi.bitrate_upper / 1000);
    
    // The blocksizes field might be named differently in the version of libvorbis you're using
    // Commenting these out for now - you'll need to check the actual vorbis_info structure
    // info->blocksize0 = context->vi.blocksizes[0];
    // info->blocksize1 = context->vi.blocksizes[1];
    
    // Use default values instead
    info->blocksize0 = 0;
    info->blocksize1 = 0;
    
    info->granulePosition = context->granulePosition;
    
    return OGGVORBIS_SUCCESS;
}

// Get decoded PCM data
OggVorbisError OggVorbisDecoderGetPCMData(OggVorbisDecoderContext* context, float** pcmData, int* samplesDecoded) {
    if (context == NULL || pcmData == NULL || samplesDecoded == NULL || !context->initialized) {
        return OGGVORBIS_ERROR_INVALID_SETUP;
    }
    
    if (context->pcmOutput == NULL || context->pcmSamples <= 0) {
        *pcmData = NULL;
        *samplesDecoded = 0;
        return OGGVORBIS_SUCCESS;
    }
    
    // Allocate memory for interleaved PCM data
    int channels = context->pcmChannels;
    int samples = context->pcmSamples;
    int totalSamples = samples * channels;
    
    float* interleavedPCM = (float*)malloc(totalSamples * sizeof(float));
    if (interleavedPCM == NULL) {
        return OGGVORBIS_ERROR_OUT_OF_MEMORY;
    }
    
    // Interleave the PCM data from multiple channels
    // libvorbis provides PCM data as float** where each channel is a separate array
    // We need to interleave them in the pattern L R L R for stereo
    printf("OggVorbis: Interleaving %d samples from %d channels\n", samples, channels);
    for (int i = 0; i < samples; i++) {
        for (int ch = 0; ch < channels; ch++) {
            // Access the sample at position i for channel ch
            float sample = context->pcmOutput[ch][i];
            // Store it in the interleaved array
            interleavedPCM[i * channels + ch] = sample;
            
            // Debug the first few samples
            if (i < 5) {
                printf("OggVorbis: Sample[%d][%d] = %f\n", i, ch, sample);
            }
        }
    }
    
    *pcmData = interleavedPCM;
    *samplesDecoded = samples;
    
    return OGGVORBIS_SUCCESS;
}

// Seek to a specific time position (in seconds)
OggVorbisError OggVorbisDecoderSeek(OggVorbisDecoderContext* context, double timeInSeconds) {
    // Note: This is a simplified implementation that doesn't actually seek
    // A real implementation would need to store page offsets and granule positions
    // to enable seeking, which requires more complex handling of the input data
    
    return OGGVORBIS_ERROR_INVALID_SETUP;
}

// Reset the decoder
OggVorbisError OggVorbisDecoderReset(OggVorbisDecoderContext* context) {
    if (context == NULL) {
        return OGGVORBIS_ERROR_INVALID_SETUP;
    }
    
    // Clean up existing structures
    if (context->initialized) {
        vorbis_block_clear(&context->vb);
        vorbis_dsp_clear(&context->vd);
        context->initialized = 0;
    }
    
    if (context->streamInitialized) {
        ogg_stream_clear(&context->os);
        context->streamInitialized = 0;
    }
    
    ogg_sync_clear(&context->oy);
    ogg_sync_init(&context->oy);
    
    vorbis_comment_clear(&context->vc);
    vorbis_info_clear(&context->vi);
    
    vorbis_info_init(&context->vi);
    vorbis_comment_init(&context->vc);
    
    // Free comment storage
    if (context->commentKeys != NULL) {
        for (int i = 0; i < context->commentCount; i++) {
            if (context->commentKeys[i] != NULL) {
                free(context->commentKeys[i]);
            }
            if (context->commentValues[i] != NULL) {
                free(context->commentValues[i]);
            }
        }
        free(context->commentKeys);
        free(context->commentValues);
        context->commentKeys = NULL;
        context->commentValues = NULL;
    }
    
    context->headersParsed = 0;
    context->granulePosition = 0;
    context->totalSamples = 0;
    context->currentSample = 0;
    context->commentCount = 0;
    
    context->pcmOutput = NULL;
    context->pcmSamples = 0;
    context->pcmChannels = 0;
    
    return OGGVORBIS_SUCCESS;
}

// Get a comment from the Vorbis stream
const char* OggVorbisDecoderGetComment(OggVorbisDecoderContext* context, const char* key) {
    if (context == NULL || key == NULL || !context->initialized) {
        return NULL;
    }
    
    for (int i = 0; i < context->commentCount; i++) {
        if (strcmp(context->commentKeys[i], key) == 0) {
            return context->commentValues[i];
        }
    }
    
    return NULL;
}

// Get all comments from the Vorbis stream
int OggVorbisDecoderGetCommentCount(OggVorbisDecoderContext* context) {
    if (context == NULL || !context->initialized) {
        return 0;
    }
    
    return context->commentCount;
}

void OggVorbisDecoderGetCommentPair(OggVorbisDecoderContext* context, int index, const char** key, const char** value) {
    if (context == NULL || !context->initialized || index < 0 || index >= context->commentCount) {
        if (key) *key = NULL;
        if (value) *value = NULL;
        return;
    }
    
    if (key) *key = context->commentKeys[index];
    if (value) *value = context->commentValues[index];
}
