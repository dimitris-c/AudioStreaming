#!/usr/bin/env bash
# Generates the Ogg fixtures used by OggVorbisOpenTests into <out-dir> (default: the
# directory of this script). Needs ffmpeg with libvorbis, libopus, libspeex and flac,
# plus python3. The committed files were made with ffmpeg n9.0.2; other builds may
# produce different bytes.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${1:-$HERE}"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FF=(ffmpeg -hide_banner -loglevel error -y)
BITEXACT=(-fflags +bitexact -flags:a +bitexact)
tone() { echo "sine=frequency=440:sample_rate=$1:duration=$2"; }

# A Vorbis comment with a 60000-byte METADATA_BLOCK_PICTURE, so the header pages end at
# about 81 KB, past the first 64 KiB read of a local file.
python3 - "$TMP/picture.ffmeta" <<'PY'
import base64, random, struct, sys
payload = bytes(random.Random(60000).getrandbits(8) for _ in range(60000))
mime = b"image/jpeg"
block = (struct.pack(">I", 3) + struct.pack(">I", len(mime)) + mime + struct.pack(">I", 0)
         + struct.pack(">IIII", 500, 500, 24, 0) + struct.pack(">I", len(payload)) + payload)
with open(sys.argv[1], "w") as out:
    out.write(";FFMETADATA1\nMETADATA_BLOCK_PICTURE=" + base64.b64encode(block).decode() + "\n")
PY

# 3 s of audio follow, so the decoder has more than 4096 bytes left after it opens.
"${FF[@]}" -f lavfi -i "$(tone 44100 3)" -i "$TMP/picture.ffmeta" -map 0:a -map_metadata 1 \
  -c:a libvorbis -q:a 10 -ac 2 "${BITEXACT[@]}" "$OUT/vorbis-large-header.ogg"
# About 5 KB, below the 16384 bytes the decoder waits for before its first open.
"${FF[@]}" -f lavfi -i "$(tone 44100 1)" -map_metadata -1 \
  -c:a libvorbis -q:a 0 -ac 1 "${BITEXACT[@]}" "$OUT/vorbis-small.ogg"
# 3 s in five Ogg pages (about 51 KB); its last page covers the final second.
"${FF[@]}" -f lavfi -i "$(tone 44100 3)" -map_metadata -1 \
  -c:a libvorbis -q:a 10 -ac 2 "${BITEXACT[@]}" "$OUT/vorbis-plain-3s.ogg"
# Other codecs in an Ogg container, which the Vorbis decoder cannot open.
"${FF[@]}" -f lavfi -i "$(tone 48000 1)" -map_metadata -1 \
  -c:a libopus -b:a 64k -ac 2 "${BITEXACT[@]}" -f ogg "$OUT/opus-in-ogg.ogg"
"${FF[@]}" -f lavfi -i "$(tone 44100 1)" -map_metadata -1 \
  -c:a flac -ac 1 "${BITEXACT[@]}" -f ogg "$OUT/flac-in-ogg.oga"
"${FF[@]}" -f lavfi -i "$(tone 16000 1)" -map_metadata -1 \
  -c:a libspeex -ac 1 "${BITEXACT[@]}" -f ogg "$OUT/speex-in-ogg.ogg"
