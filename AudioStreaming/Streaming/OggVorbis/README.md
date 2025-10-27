# Ogg Vorbis Support for AudioStreaming

This directory contains the implementation of Ogg Vorbis support for the AudioStreaming library.

## Overview

The Ogg Vorbis support consists of:

1. **OggVorbisBridge.h/.c**: C wrapper for the libvorbis/libogg libraries
2. **OggVorbisDecoder.swift**: Swift wrapper for the C bridge
3. **OggVorbisStreamProcessor.swift**: Integration with the AudioStreaming framework

## Dependencies

This implementation requires the following external libraries:

- **libvorbis**: The Vorbis audio decoder
- **libogg**: The Ogg container format library

These libraries need to be linked to the project. You can install them using a package manager like CocoaPods, Carthage, or Swift Package Manager.

## Usage

Ogg Vorbis files are automatically detected and processed by the AudioStreaming library. You can play Ogg Vorbis files the same way you play other audio formats:

```swift
let player = AudioPlayer()
player.play(url: URL(string: "https://example.com/audio.ogg")!)
```

Or for local files:

```swift
let player = AudioPlayer()
player.play(url: URL(fileURLWithPath: "/path/to/audio.ogg"))
```

## Features

- Streaming playback of remote Ogg Vorbis files
- Local file playback
- Seeking support
- Metadata extraction
- Gapless playback

## Implementation Details

The implementation follows these steps:

1. Detect Ogg Vorbis files by file extension or MIME type
2. Parse Ogg pages and extract Vorbis packets
3. Decode Vorbis audio data to PCM
4. Convert PCM to the format required by AVAudioEngine
5. Handle seeking by resetting the decoder and seeking to the appropriate position

## Limitations

- Seeking is not as precise as with other formats due to the nature of Ogg Vorbis streams
- Performance may be lower compared to formats with native Apple support
- Memory usage may be higher due to the need for additional buffers

## Future Improvements

- Optimize memory usage
- Improve seeking precision
- Add support for Opus in Ogg containers
