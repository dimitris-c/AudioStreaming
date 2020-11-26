![AudioStreaming CI](https://github.com/dimitris-c/AudioStreaming/workflows/AudioStreaming%20CI/badge.svg)

# AudioStreaming
An AudioPlayer/Streaming library for iOS written in Swift, allows playback of online audio streaming, local file as well as gapless queueing.

Under the hood `AudioStreaming` uses `AVAudioEngine` and `CoreAudio` for playback and provides an easy way of applying real-time [audio enhancements](https://developer.apple.com/documentation/avfoundation/audio_playback_recording_and_processing/avaudioengine/audio_units?language=swift).

#### Supported audio
- Online streaming (Shoutcast/ICY streams) with metadata parsing 
- AIFF, AIFC, WAVE, CAF, NeXT, ADTS, MPEG Audio Layer 3, AAC audio formats
- M4A (_Optimized files only_)

Known limitations: 
- As described above non-optimised M4A files are not supported this is a limitation of [AudioFileStream Services](https://developer.apple.com/documentation/audiotoolbox/audio_file_stream_services?language=swift) 


# Requirements
 - iOS 12.0+
 - Swift 5.x

# Using AudioStreaming

### Playing an audio source over HTTP
Note: You need to keep a reference to the `AudioPlayer` object
```
let player = AudioPlayer()
player.play(url: URL(string: "https://your-remote-url/to/audio-file.mp3")!)
```

### Playing a local file 
```
let player = AudioPlayer()
player.play(url: URL(fileURLWithPath: "your-local-path/to/audio-file.mp3")!)
```
### Queueing audio files
```
let player = AudioPlayer()
player.queue(url: URL(string: "https://your-remote-url/to/audio-file.mp3")!)
player.queue(url: URL(fileURLWithPath: "your-local-path/to/audio-file.mp3")!)
```

### Adjusting playback properties
```
let player = AudioPlayer()
player.play(url: URL(fileURLWithPath: "your-local-path/to/audio-file.mp3")!)
// adjust the playback rate
player.rate = 2.0

// adjusting the volume
player.volume = 0.5

// mute/unmute the audio
player.mute = true

// pause the playback
player.pause()

// resume the playback
player.resume()

// stop the playback
player.stop()

// seeking to to a time (in seconds)
player.seek(to: 10)
```

### Audio playback properties
```
let player = AudioPlayer()
player.play(url: URL(fileURLWithPath: "your-local-path/to/audio-file.mp3")!)

// To get the audio file duration
let duration = player.duration

// To get the progress of the player
let progress = player.progress

// To get the state of the player, for possible values view the `AudioPlayerState` enum
let state = player.state

// To get the stop reason of the player, for possible values view the `AudioPlayerStopReason` enum
let state = player.stopReason
```

### AudioPlayer Delegate
You can inspect various callbacks by using the `delegate` property of the `AudioPlayer` to get informed about the player state, errors etc.
View the [AudioPlayerDelegate](AudioStreaming/Streaming/AudioPlayer/AudioPlayerDelegate.swift) for more details

```
let player = AudioPlayer()
player.play(url: URL(fileURLWithPath: "your-local-path/to/audio-file.mp3")!)

player.delegate = self // an object conforming to AudioPlayerDelegate

// observing the audio player state, provides the new and previous state of the player.
func audioPlayerStateChanged(player: AudioPlayer, with newState: AudioPlayerState, previous: AudioPlayerState) {}
```

### Adding custom audio nodes to AudioPlayer
`AudioStreaming` provides an easy way to attach/remove `AVAudioNode`(s).
This provides a powerful way of adjusting the playback audio with various enchncements 

```
let reverbNode = AVAudioUnitReverb()
reverbNode.wetDryMix = 50 

let player = AudioPlayer()
// attach a single node
player.attach(node: reverbNode)

// detach a single node
player.detach(node: reverbNode)

// detach all custom added nodes
player.detachCustomAttachedNodes()
```

The example project shows an example of adding a custom `AVAudioUnitEQ` node for adding equaliser to the `AudioPlayer`

# Installation

### Cocoapods

[Cocoapods](https://cocoapods.org/) is a dependency manager for Cocoa projects. You can install it with the following command:
```
$ gem install cocoapods
```

To intergrate AudioStreaming with [Cocoapods](https://cocoapods.org/) to your Xcode project add the following to your `Podfile`:
```
pod 'AudioStreaming'
```

### Swift Package Manager

On Xcode 11.0+ you can add a new dependency by going to **File / Swift Packages / Add Package Dependency...**
and enter package repository URL https://github.com/dimitris-c/AudioStreaming.git, then follow the instructions.

### Carthage

[Carthage](https://github.com/Carthage/Carthage) is a decentralized dependency manager that builds your dependencies and provides you with frameworks.

You can install Carthage with Homebrew using the following command:
```
$ brew update
$ brew install carthage
```

To integrate AudioStreaming into your Xcode project using Carthage, add the following to your `Cartfile`:
```
github "dimitris-c/AudioStreaming"
```
Visit [installation instructions](https://github.com/Carthage/Carthage#adding-frameworks-to-an-application) on Carthage to install the framework

# Licence

AudioStreaming is available under the MIT license. See the LICENSE file for more info.

# Attributions
This librabry takes inspiration on the already battled-tested streaming library, [StreamingKit](https://github.com/tumtumtum/StreamingKit).
Big 🙏 to Thong Nguyen (@tumtumtum) and Matt Gallagher (@mattgallagher) for [AudioStreamer](https://github.com/mattgallagher/AudioStreamer)
