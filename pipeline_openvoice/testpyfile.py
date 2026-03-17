#!/usr/bin/env python3
"""
Clone a voice with OpenVoice:
  1. Extract speaker embedding from a reference .wav
  2. Run TTS on a text script, using that embedding
  3. Save the synthesized voice as an output .wav
"""

import argparse
import sys
import os
from pathlib import Path
sys.path.append(os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))
import torch
from openvoice_cli import se_extractor
import numpy as np
from MeloTTS.melo.api import TTS

def clone_voice(
    reference_wav: str,
    script_path: str | None,
    text: str | None,
    output_wav: str,
    checkpoint_path: str = "checkpoints",
    speaker: str = "default",
    language: str = "en",
    embedding_path: str | None = None,
) -> Path:
    """Run the full OpenVoice cloning pipeline and return output path."""
    reference_wav = Path(reference_wav).expanduser().resolve()
    output_wav = Path(output_wav).expanduser().resolve()
    checkpoint_path = Path(checkpoint_path).expanduser().resolve()

    if not reference_wav.exists():
        raise FileNotFoundError(f"Reference wav not found: {reference_wav}")

    # Load or read text
    if text is None:
        if script_path is None:
            raise ValueError("Either --text or --script must be provided.")
        script_path = Path(script_path).expanduser().resolve()
        if not script_path.exists():
            raise FileNotFoundError(f"Script file not found: {script_path}")
        text = script_path.read_text(encoding="utf-8")

    # Prepare embedding output
    if embedding_path is None:
        embedding_path = output_wav.with_name("ref_embedding.npy")
    else:
        embedding_path = Path(embedding_path).expanduser().resolve()

    embedding_path.parent.mkdir(parents=True, exist_ok=True)
    output_wav.parent.mkdir(parents=True, exist_ok=True)

    print("🎤  Extracting speaker embedding…")
    vc_model = load_model(device="cuda" if torch.cuda.is_available() else "cpu")
    se, audio_name = se_extractor.get_se(str(reference_wav), vc_model)
    np.save(str(embedding_path), se.cpu().numpy())
    print("🗣️   Synthesizing speech with OpenVoice…")
    TTS.tts(
        text=text,
        speaker=speaker,
        language=language,
        se_path=str(embedding_path),
        checkpoint_path=str(checkpoint_path),
        output_path=str(output_wav),
    )

    print(f"✅  Cloned voice saved to: {output_wav}")
    return output_wav


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Clone a voice with OpenVoice from a reference wav and script."
    )
    p.add_argument("--reference", required=True, help="Reference .wav file (source voice).")
    g = p.add_mutually_exclusive_group(required=True)
    g.add_argument("--script", help="Path to a UTF‑8 text file.")
    g.add_argument("--text", help="Inline text to synthesize.")
    p.add_argument("--out", default="voice.wav", help="Output .wav file (default: voice.wav).")
    p.add_argument("--checkpoint-path", default="checkpoints", help="Directory with OpenVoice checkpoints.")
    p.add_argument("--speaker", default="default", help="Speaker ID (default: 'default').")
    p.add_argument("--language", default="en", help="Language code (default: en).")
    p.add_argument("--embedding-path", help="Optional .npy file to save the embedding.")
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
        embedding_path=args.embedding_path,
    )


if __name__ == "__main__":
    sys.exit(main())
