#!/usr/bin/env python3

import argparse
import sys
import os
import re
import tempfile
from pathlib import Path
import sys
import os
from pathlib import Path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '../MeloTTS')))
import torch
from MeloTTS.melo.api import TTS
from openvoice_cli.api import ToneColorConverter

# ── Constants ────────────────────────────────────────
CLEAN_RE_MARKDOWN = re.compile(r"[*_`#>]+")
CLEAN_RE_EMOJI = re.compile(r"[\U00010000-\U0010FFFF]", flags=re.UNICODE)
CLEAN_RE_BADCHAR = re.compile(r"[^A-Za-z0-9 \n\.\,\!\?\;\:\'\"\-\(\)]")

DEVICE = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"


# ── Text Cleaning ─────────────────────────────────────
# removes anything like emoji's or marcdown
def clean_text(text: str) -> str:
    t = CLEAN_RE_MARKDOWN.sub(" ", text)
    t = CLEAN_RE_EMOJI.sub(" ", t)
    t = CLEAN_RE_BADCHAR.sub(" ", t)
    t = re.sub(r"([.!?]){2,}", r"\1", t)
    t = re.sub(r"\s+", " ", t).strip()
    if t and not t[0].isalnum():
        t = "Hi. " + t
    return t


# ── Voice Cloning ─────────────────────────────────────
def clone_voice(
    reference_wav: str | None,
    script_path: str | None,
    text: str | None,
    output_wav: str,
    checkpoint_path: str = "checkpoints_v2",
    speaker: str = "EN-Default",
    language: str = "EN"
) -> Path:
    output_wav = Path(output_wav).expanduser().resolve()
    checkpoint_path = Path(checkpoint_path).expanduser().resolve()

    if reference_wav:
        reference_wav_path = Path(reference_wav).expanduser().resolve()
        if not reference_wav_path.exists():
            raise FileNotFoundError(f"Reference wav not found: {reference_wav_path}")

    # Load text
    if text is None:
        if script_path is None:
            raise ValueError("Either --text or --script must be provided.")
        script_path = Path(script_path).expanduser().resolve()
        if not script_path.exists():
            raise FileNotFoundError(f"Script file not found: {script_path}")
        text = script_path.read_text(encoding="utf-8")

    text = clean_text(text)
    if not text:
        raise ValueError("Nothing left after cleaning the text.")

    # Resolve checkpoint layout
    checkpoint_roots = []
    if (checkpoint_path / "checkpoints_v2").exists():
        checkpoint_roots.append(checkpoint_path / "checkpoints_v2")
    checkpoint_roots.append(checkpoint_path)

    def first_existing(candidates: list[Path], label: str) -> Path:
        for c in candidates:
            if c.exists():
                return c
        looked = "\n - ".join(str(c) for c in candidates)
        raise FileNotFoundError(f"Could not find {label}. Looked in:\n - {looked}")

    base_se_path = first_existing(
        [
            root / "base_speakers" / "ses" / "en-default.pth"
            for root in checkpoint_roots
        ] + [
            root / "base_speakers" / "en-default.pth"
            for root in checkpoint_roots
        ],
        "base speaker embedding (en-default.pth)",
    )
    converter_config_path = first_existing(
        [root / "converter" / "config.json" for root in checkpoint_roots],
        "converter config.json",
    )
    converter_ckpt_path = first_existing(
        [root / "converter" / "checkpoint.pth" for root in checkpoint_roots],
        "converter checkpoint.pth",
    )
    base_se = torch.load(base_se_path, map_location=DEVICE)

    # Load TTS model
    tts = TTS(language=language, device=DEVICE)
    speaker_ids = tts.hps.data.spk2id
    if speaker not in speaker_ids:
        raise KeyError(f"Speaker '{speaker}' not found. Available: {list(speaker_ids.keys())}")
    sid = speaker_ids[speaker]

    # Generate intermediate audio
    tmp_dir = tempfile.mkdtemp()
    base_out_path = os.path.join(tmp_dir, "base.wav")
    try:
        tts.tts_to_file(text, sid, base_out_path)
    except TypeError:
        tts.tts_to_file(text, sid, base_out_path)

    # Convert voice style
    converter = ToneColorConverter(str(converter_config_path), device=DEVICE)
    converter.load_ckpt(str(converter_ckpt_path))
    converter.convert(
        audio_src_path=base_out_path,
        src_se=base_se,
        tgt_se=base_se,
        output_path=output_wav,
        message="@OpenVoiceCLI"
    )

    print(f"✅ Cloned voice saved to: {output_wav}")
    return output_wav


# ── CLI Argument Parsing ──────────────────────────────
def parse_args(argv=None):
    p = argparse.ArgumentParser(description="Clone a voice using OpenVoice with base embedding.")
    p.add_argument("--reference", help="Optional reference .wav file (for matching tone).")
    group = p.add_mutually_exclusive_group(required=True)
    group.add_argument("--script", help="Text script file.")
    group.add_argument("--text", help="Inline text to synthesize.")
    p.add_argument("--out", default="voice.wav", help="Output .wav file (default: voice.wav).")
    p.add_argument("--checkpoint-path", default="checkpoints", help="OpenVoice checkpoints directory.")
    p.add_argument("--speaker", default="EN-Default", help="MeloTTS speaker ID.")
    p.add_argument("--language", default="EN", help="Language code.")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    clone_voice(
        reference_wav=args.reference,
        script_path=args.script,
        text=args.text,
        output_wav=args.out,
        checkpoint_path=args.checkpoint_path,
        speaker=args.speaker,
        language=args.language,
    )


if __name__ == "__main__":
    sys.exit(main())
