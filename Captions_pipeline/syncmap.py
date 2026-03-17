#!/usr/bin/env python3
import json
from pathlib import Path
import argparse

def flatten(inp: Path, out: Path):
    with open(inp, "r", encoding="utf-8") as f:
        data = json.load(f)

    # Detect structure
    if "fragments" in data:
        fragments = data["fragments"]
    elif "segments" in data:
        fragments = data["segments"]
    else:
        raise KeyError("No 'fragments' or 'segments' found in input JSON.")

    words_data = []

    for fragment in fragments:
        # Prefer explicit word-level timing
        if "words" in fragment and isinstance(fragment["words"], list):
            for w in fragment["words"]:
                words_data.append({
                    "word": w.get("word", "").strip(),
                    "start": w.get("start", None),
                    "end": w.get("end", None),
                    "score": w.get("score", None)
                })
        else:
            # Fallback to fragment-level timing and text
            words_data.append({
                "word": fragment.get("text", "").strip(),
                "start": fragment.get("start", None) or fragment.get("begin", None),
                "end": fragment.get("end", None),
                "score": None
            })

    with open(out, "w", encoding="utf-8") as f:
        json.dump(words_data, f, indent=2, ensure_ascii=False)

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Flatten WhisperX or syncmap JSON to word-level data.")
    parser.add_argument("--in", dest="inp", required=True, help="Input JSON file (WhisperX output or syncmap format).")
    parser.add_argument("--out", dest="out", required=True, help="Output JSON file with flattened word-level timing.")
    args = parser.parse_args()

    flatten(Path(args.inp), Path(args.out))
