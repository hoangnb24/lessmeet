#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# These private synthetic fixtures need installed macOS voices and ffmpeg.
# Do not download voices or record from a device.
command -v say >/dev/null
command -v ffmpeg >/dev/null
mkdir -p .artifacts/local-inference
fixture_dir="$(mktemp -d "$PWD/.artifacts/local-inference/fixtures.XXXXXX")"

require_audible_samples() {
  local name="$1"
  ffmpeg -nostdin -hide_banner -i "$fixture_dir/$name.aiff" \
    -af volumedetect -f null - >/dev/null 2>"$fixture_dir/$name-levels.log"
  if ! awk '/max_volume:/ { for (i=1; i<NF; i++) if ($i == "max_volume:") {
    value=$(i+1); if (value ~ /^-?[0-9]+([.][0-9]+)?$/ && value > -80) audible=1
  }} END { exit !audible }' "$fixture_dir/$name-levels.log"; then
    printf 'Speech fixture %s has no audible samples; inference input was not created. Evidence: %s\n' \
      "$name" "$fixture_dir" >&2
    exit 1
  fi
}

say -v Samantha -r 160 -o "$fixture_dir/first.aiff" \
  "We are testing a local meeting recorder. The project decision is to keep all audio on this computer. We will download the models once, then process recordings without an internet connection. Please review the transcript after the meeting."
say -v Daniel -r 155 -o "$fixture_dir/second.aiff" \
  "I agree with the decision. My next task is to check the model download and the speaker labels. The deadline is Friday afternoon. If the download is canceled, it must not restart without a retry. We will keep the original recording."
require_audible_samples first
require_audible_samples second
ffmpeg -hide_banner -loglevel error -i "$fixture_dir/first.aiff" -i "$fixture_dir/second.aiff" \
  -filter_complex '[0:a]aresample=16000,aformat=channel_layouts=mono,apad=pad_dur=2[a];[1:a]aresample=16000,aformat=channel_layouts=mono,apad=pad_dur=2[b];[a][b]concat=n=2:v=0:a=1[out]' \
  -map '[out]' -c:a pcm_s16le "$fixture_dir/dialogue.wav"
ffmpeg -nostdin -n -hide_banner -loglevel error -i "$fixture_dir/dialogue.wav" \
  -c:a aac -b:a 96k "$fixture_dir/dialogue.m4a"
ffmpeg -hide_banner -loglevel error -stream_loop -1 -i "$fixture_dir/dialogue.wav" \
  -t 650 -ar 16000 -ac 1 -c:a pcm_s16le "$fixture_dir/long-dialogue.wav"
ffmpeg -hide_banner -loglevel error -f lavfi -i anullsrc=r=16000:cl=mono \
  -t 10 -c:a pcm_s16le "$fixture_dir/silence.wav"
shasum -a 256 "$fixture_dir/dialogue.wav" "$fixture_dir/dialogue.m4a" \
  "$fixture_dir/long-dialogue.wav" "$fixture_dir/silence.wav"
printf 'Synthetic fixture directory: %s\n' "$fixture_dir"
