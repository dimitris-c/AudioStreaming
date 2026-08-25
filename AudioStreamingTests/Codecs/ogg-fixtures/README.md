# Ogg test fixtures

Short synthetic tones, generated with ffmpeg so they carry no third-party
content. Each is a pure sine, which lets the tests assert on decoded sample
values (via zero-crossing frequency) rather than only on frame counts.

| File | Contents |
|---|---|
| `opus-tone-mono-48k.opus` | 2 s, 440 Hz, mono, 96 kbps |
| `opus-tone-stereo-48k.opus` | 2 s, 440 Hz left / 660 Hz right, 96 kbps |
| `opus-declares-44k-input.opus` | 2 s, 440 Hz mono, with `OpusHead.input_sample_rate` set to 44100 |
| `opus-large-header.opus` | 1 s, 440 Hz stereo, with a ~20 KB comment header |
| `vorbis-tone-stereo-44k.ogg` | 2 s, 440 Hz stereo Vorbis, q3 |

Regenerate with:

```sh
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
       -ac 1 -c:a libopus -b:a 96k opus-tone-mono-48k.opus

ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=2" \
       -f lavfi -i "sine=frequency=660:sample_rate=48000:duration=2" \
       -filter_complex "[0:a][1:a]join=inputs=2:channel_layout=stereo[a]" \
       -map "[a]" -c:a libopus -b:a 96k opus-tone-stereo-48k.opus

ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=44100:duration=2" \
       -ac 2 -c:a libvorbis -q:a 3 vorbis-tone-stereo-44k.ogg

ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" \
       -ac 2 -c:a libopus -b:a 96k -metadata comment="$(python3 -c 'print("X"*20000)')" \
       opus-large-header.opus
```

Two fixtures are deliberate edge cases:

- **`opus-declares-44k-input.opus`** guards the Opus pitch-shift bug.
  `OpusHead.input_sample_rate` describes the material that was encoded, not the
  output; Opus always decodes at 48 kHz. ffmpeg resamples before encoding and
  always writes 48000, so the field was rewritten to 44100 afterwards and the
  page CRC recomputed.
- **`opus-large-header.opus`** has headers running past byte 20230, beyond the
  16384-byte threshold at which `OggStreamProcessor` first attempts an open, so
  the first attempt is guaranteed to fail and the retry path is exercised.
