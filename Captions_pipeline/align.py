#!/usr/bin/env python3
"""
align.py – align voice.wav with the exact script using WhisperX.
Outputs:
  • captions.srt   (viewer captions)
  • captions_sync.json  (word-level timing for animation or interruption)
Requires:
  pip install git+https://github.com/m-bain/whisperx.git
  pip install torch --extra-index-url https://download.pytorch.org/whl/cpu
"""
import json
import argparse
from pathlib import Path
import whisperx
import os
from datetime import datetime

def format_timestamp(seconds: float) -> str:
    """Format seconds into SRT hh:mm:ss,ms"""
    hrs = int(seconds // 3600)
    mins = int((seconds % 3600) // 60)
    secs = int(seconds % 60)
    ms = int((seconds - int(seconds)) * 1000)
    return f"{hrs:02}:{mins:02}:{secs:02},{ms:03}"

def align(wav_path, script_path, srt_out, json_out):
    device = "cpu"  # Change to "cuda" if using GPU
    print(f"🔁 Starting alignment for: {wav_path} + {script_path}")

    # Remove old files if they exist
    for f in [srt_out, json_out]:
        if f.exists():
            print(f"🧹 Removing old file: {f}")
            f.unlink()

    model = whisperx.load_model("base", device, compute_type="int8")

    audio = whisperx.load_audio(str(wav_path))
    result = model.transcribe(audio)

    with open(script_path, "r", encoding="utf-8") as f:
        exact_script = f.read().strip()

    model_a, metadata = whisperx.load_align_model(language_code=result["language"], device=device)
    result_aligned = whisperx.align(result["segments"], model_a, metadata, audio, device)

    # Write SRT file
    with srt_out.open("w", encoding="utf-8") as srt_file:
        for i, seg in enumerate(result_aligned["segments"], start=1):
            srt_file.write(f"{i}\n")
            srt_file.write(f"{format_timestamp(seg['start'])} --> {format_timestamp(seg['end'])}\n")
            srt_file.write(f"{seg['text'].strip()}\n\n")

    # Write word-level JSON
    with json_out.open("w", encoding="utf-8") as jf:
        json.dump(result_aligned, jf, ensure_ascii=False, indent=2)

    print(f"✅ Alignment complete →\n  • {srt_out}\n  • {json_out}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--wav", required=True, help="Path to voice.wav")
    parser.add_argument("--script", required=True, help="Path to script.txt")
    parser.add_argument("--srt", required=False, help="Output captions SRT")
    parser.add_argument("--json", required=False, help="Output word-level JSON")
    parser.add_argument("--timestamp", action="store_true", help="Add timestamp to output filenames")

    args = parser.parse_args()

    wav_path = Path(args.wav)
    script_path = Path(args.script)

    # Default output file names
    if args.timestamp:
        ts = datetime.now().strftime("%Y%m%d_%H%M%S")
        srt_out = wav_path.parent / f"captions_{ts}.srt"
        json_out = wav_path.parent / f"captions_sync_{ts}.json"
    else:
        srt_out = Path(args.srt) if args.srt else wav_path.parent / "captions.srt"
        json_out = Path(args.json) if args.json else wav_path.parent / "captions_sync.json"

    align(wav_path, script_path, srt_out, json_out)