#!/usr/bin/env python3
import argparse
import subprocess
import sys
import uuid
from pathlib import Path


def generate_talking_head(
    audio_path: str,
    avatar_path: str,
    result_dir: str = "talking_head_output",
    sadtalker_dir: str | None = None,
    python_exec: str | None = None,
    enhancer: str = "gfpgan",
    preprocess: str = "full",
    still: bool = True,
    extra_args: list[str] | None = None,
) -> Path | None:
    """
    Generate a talking-head video using SadTalker.

    Parameters
    ----------
    audio_path : str
        Path to the .wav (or other supported) audio file.
    avatar_path : str
        Path to the source image.
    result_dir : str
        Base folder to store the output; a unique subfolder is created each run.
    sadtalker_dir : str | None
        Path to the SadTalker repo (folder containing inference.py). Defaults to CWD/SadTalker.
    python_exec : str | None
        Python executable to call (defaults to current interpreter: sys.executable).
        Leave None if you run this via `conda run -n sadtalker ...` or inside the venv.
    enhancer : str
        Enhancer option for SadTalker (e.g., gfpgan, None).
    preprocess : str
        Preprocess mode for SadTalker (e.g., full, crop, resize).
    still : bool
        Whether to pass the --still flag.
    extra_args : list[str] | None
        Extra CLI args forwarded to SadTalker (advanced use).

    Returns
    -------
    Path | None
        Path to the generated .mp4 file, or None if not found/failed.
    """
    audio_path = Path(audio_path).resolve()
    avatar_path = Path(avatar_path).resolve()
    out_root = Path(result_dir).resolve()
    out_root.mkdir(parents=True, exist_ok=True)

    session_dir = out_root  # flat structure
    session_dir.mkdir(parents=True, exist_ok=True)
    if sadtalker_dir is None:
        sadtalker_dir = (Path.cwd() / "SadTalker").resolve()
    else:
        sadtalker_dir = Path(sadtalker_dir).resolve()

    inference_py = sadtalker_dir / "inference.py"
    if not inference_py.exists():
        print(f"❌ inference.py not found at {inference_py}", file=sys.stderr)
        return None

    if python_exec is None:
        python_exec = sys.executable  # assume we've already activated the right env

    cmd = [
        str(python_exec),
        str(inference_py),
        "--driven_audio", str(audio_path),
        "--source_image", str(avatar_path),
        "--result_dir", str(session_dir),
        "--preprocess", preprocess,
    ]

    if enhancer:
        cmd.extend(["--enhancer", enhancer])
    if still:
        cmd.append("--still")
    if extra_args:
        cmd.extend(extra_args)

    print("🚀 Running SadTalker…")
    # Capture output for debugging if needed
    proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    if proc.returncode != 0:
        print("❌ SadTalker failed:\n", proc.stderr, file=sys.stderr)
        return None

    # Find the generated video
    mp4s = list(session_dir.glob("*.mp4"))
    if not mp4s:
        print("⚠️ No output video found in:", session_dir, file=sys.stderr)
        return None

    final_video = mp4s[0]
    print("✅ Talking head generated:", final_video)
    return final_video


def parse_args(argv=None):
    p = argparse.ArgumentParser(
        description="Generate a talking-head video with SadTalker."
    )
    p.add_argument("--audio", required=True, help="Path to audio file (.wav recommended).")
    p.add_argument("--avatar", required=True, help="Path to source image.")
    p.add_argument("--out", default="talking_head_output", help="Output base directory.")
    p.add_argument("--sadtalker-dir", help="Path to SadTalker repo (contains inference.py). Defaults to ./SadTalker")
    p.add_argument("--python-exec", help="Python executable to use. Defaults to current interpreter.")
    p.add_argument("--enhancer", default="gfpgan", help="Enhancer to use (gfpgan / None).")
    p.add_argument("--preprocess", default="full", help="Preprocess mode (full/crop/resize/etc.).")
    p.add_argument("--no-still", dest="still", action="store_false", help="Do NOT pass --still.")
    p.add_argument("--extra", nargs=argparse.REMAINDER, help="Extra args passed directly to SadTalker.")
    return p.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    generate_talking_head(
        audio_path=args.audio,
        avatar_path=args.avatar,
        result_dir=args.out,
        sadtalker_dir=args.sadtalker_dir,
        python_exec=args.python_exec,
        enhancer=args.enhancer if args.enhancer.lower() != "none" else None,
        preprocess=args.preprocess,
        still=args.still,
        extra_args=args.extra if args.extra else None,
    )


if __name__ == "__main__":
    sys.exit(main())