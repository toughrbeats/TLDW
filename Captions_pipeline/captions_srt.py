#!/usr/bin/env python3
import json
from pathlib import Path
from datetime import timedelta

# Convert seconds (float) to SRT timestamp (HH:MM:SS,mmm)
def seconds_to_srt_time(seconds: float) -> str:
    td = timedelta(seconds=seconds)
    return str(td)[:-3].replace('.', ',')

# Build SRT blocks from WhisperX output using fixed time windows
def build_fixed_subtitles(json_path: Path, max_duration: float = 2.5) -> list[str]:
    with open(json_path, "r", encoding="utf-8") as f:
        data = json.load(f)
        words = data["word_segments"]

    srt_blocks = []
    block = []
    block_start = words[0]["start"] if words else 0.0
# for every word within a certain amount of time it becomes part of a caption block
    for word in words:
        if word["end"] > block_start + max_duration:
            # finalize current block
            text = " ".join(w["word"] for w in block)
            start_time = seconds_to_srt_time(block[0]["start"])
            end_time = seconds_to_srt_time(block[-1]["end"])
            srt_blocks.append((start_time, end_time, text))

            # start new block
            block = [word]
            block_start = word["start"]
        else:
            block.append(word)

    # handle leftover block at end
    if block:
        text = " ".join(w["word"] for w in block)
        start_time = seconds_to_srt_time(block[0]["start"])
        end_time = seconds_to_srt_time(block[-1]["end"])
        srt_blocks.append((start_time, end_time, text))

    return srt_blocks

# Write to .srt format
def write_srt(srt_blocks, output_path: Path):
    with open(output_path, "w", encoding="utf-8") as f:
        for i, (start, end, text) in enumerate(srt_blocks, 1):
            f.write(f"{i}\n")
            f.write(f"{start} --> {end}\n")
            f.write(f"{text}\n\n")
    print(f"✅ SRT file written: {output_path}")

# CLI usage
if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description="Generate .srt captions from WhisperX transcript.json")
    parser.add_argument("--json", required=True, help="Path to transcript.json from WhisperX")
    parser.add_argument("--out", default="transcript.srt", help="Output .srt file path")
    parser.add_argument("--duration", type=float, default=2.5, help="Max seconds per subtitle block")
    args = parser.parse_args()

    srt_data = build_fixed_subtitles(Path(args.json), max_duration=args.duration)
    write_srt(srt_data, Path(args.out))