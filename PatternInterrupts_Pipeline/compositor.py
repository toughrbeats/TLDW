#!/usr/bin/env python3
"""
compositor.py – Pattern-interrupt engine (MoviePy 2.x edition)

Usage
-----
python compositor.py /abs/path/to/workdir/manifest.json

Dependencies
------------
pip install moviepy pillow
(FFmpeg must be in your PATH – MoviePy shells out for encoding.)
"""
from __future__ import annotations
import json, random, argparse
from pathlib import Path
from typing import List, Dict

# ── MoviePy 2 imports ──────────────────────────────────────────────────────────
from moviepy import (
    VideoFileClip,
    AudioFileClip,
    CompositeVideoClip,
    TextClip,
    ImageClip,
    ColorClip,
)
from moviepy.video.fx import Resize, FadeOut, CrossFadeOut           # ← effect classes
# add to imports at top
import re, subprocess, shlex

# ---------- ASS helpers ----------
def _ass_escape(text: str) -> str:
    # escape braces and backslashes for ASS
    return text.replace('\\', r'\\').replace('{', r'\{').replace('}', r'\}')

def _to_ass_time(t: float) -> str:
    # h:mm:ss.cs (centiseconds)
    h = int(t // 3600); t -= 3600 * h
    m = int(t // 60);   t -= 60 * m
    s = int(t)
    cs = int(round((t - s) * 100))
    return f"{h:d}:{m:02d}:{s:02d}.{cs:02d}"

def _group_words_into_lines(words, max_gap=0.40):
    """
    Groups word-level timings into subtitle 'lines' by time gaps.
    Returns list of dicts: {start, end, tokens:[{'w','start','end'}, ...]}
    """
    lines, cur = [], None
    for w in words:
        wstart = float(w["start"]); wend = float(w["end"]); token = w["word"]
        if cur is None or wstart - cur["end"] > max_gap:
            if cur: lines.append(cur)
            cur = {"start": wstart, "end": wend, "tokens": []}
        cur["tokens"].append({"w": token, "start": wstart, "end": wend})
        cur["end"] = max(cur["end"], wend)
    if cur: lines.append(cur)
    return lines

def _colorize_line(tokens, impact_set, green="&H0000FF00&", white="&H00FFFFFF&"):
    """
    Build an ASS text line from tokens, coloring the first token that belongs
    to impact_set in green using override tags, then resetting to white.
    """
    out = []
    colored_once = False
    for tok in tokens:
        word = tok["w"]
        clean = _ass_escape(word)
        if (word.strip().lower() in impact_set) and not colored_once:
            out.append(rf"{{\c{green}}}{clean}{{\c{white}}}")
            colored_once = True
        else:
            out.append(clean)
    # collapse extra spaces between tokens; keep single spaces
    return " ".join(out)

def build_ass_with_highlights(words, impact_words, font="Inter", fontsize=28):
    """
    Returns text of a full ASS file with highlighted impact words.
    'impact_words' should be a set of lowercased words to highlight.
    """
    lines = _group_words_into_lines(words)
    header = f"""[Script Info]
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Default,{font},{fontsize},&H00FFFFFF,&H000000FF,&H00000000,&H00000000,0,0,0,0,100,100,0,0,1,2,1,2,60,60,120,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
    events = []
    for L in lines:
        start = _to_ass_time(L["start"])
        end   = _to_ass_time(L["end"])
        text  = _colorize_line(L["tokens"], impact_words)
        events.append(f"Dialogue: 0,{start},{end},Default,,0000,0000,0000,,{text}")
    return header + "\n".join(events) + "\n"

# ───────────────────────────────────────────────
ASSETS_DIR = Path(__file__).parent / "assets"
EMOJI_DIR  = ASSETS_DIR / "emojis"    # 👍 🔥 🚀 pngs
FONT_BOLD  = str((ASSETS_DIR / "fonts/Inter_18pt-Bold.ttf").resolve())

# Mapping beat type -> effect list (randomly chosen)
EFFECTS = {
    "hook":      ["zoom_punch", "color_flash"],
    "takeaway":  ["word_pop"],
    "twist":     ["color_flash"],
    "cta":       ["emoji_burst"],
}

# Cool-down guard (sec) to prevent back-to-back flashes
COOLDOWN_SECONDS = 1.5

# ───────────────────────────────────────────────
def load_manifest(path: Path) -> Dict:
    man = json.loads(path.read_text())
    workdir = path.parent
    man["audio"]    = workdir / man["audio"]
    man["avatar"]   = workdir / man["avatar"]
    man["captions"] = workdir / man["captions"]   # word-level JSON
    man["beats"]    = workdir / man["beats"]
    return man

def load_word_timings(words_json: Path) -> List[Dict]:
    """Expect flat list [{word,start,end}, …] in seconds."""
    return json.loads(words_json.read_text())

def find_word_time(word_list: List[Dict], keyword: str) -> float | None:
    """Return start time (s) of the first word that matches keyword (case-insensitive)."""
    kw = keyword.lower()
    for w in word_list:
        if w["word"].strip().lower() == kw:
            return float(w["start"])
    return None

# ───────────── Effect builders (v2 style) ─────────────────
def zoom_punch(
    clip: VideoFileClip,
    t: float,
    dur: float = 0.25,
    scale: float = 1.3,
):
    """Quick zoom-in punch."""
    return (
        clip.subclipped(t, t + dur)                      # v2: .subclipped
            .with_effects([Resize(scale)])              # effect object
            .with_start(t)
            .with_end(t + dur)
            .with_position("center")
    )

def color_flash(size, t: float, dur: float = 0.12, color=(255, 255, 255)):
    return (
        ColorClip(size, color=color)
            .with_duration(dur)
            .with_start(t)
            .with_opacity(1)
            .with_effects([CrossFadeOut(dur)])
    )

def word_pop(keyword: str, t: float, dur: float = 0.45):
    txt = TextClip(
        text=keyword,
        font_size=90,                 # v2: font_size not fontsize
        font=FONT_BOLD,
        color="white",
        stroke_width=3,
        stroke_color="black",
    )
    anim = (
        txt.with_start(t)
            .with_duration(dur)
            .resized(lambda τ: 1.5 - 0.5 * (τ / dur))   # v2: .resized
            .with_effects([FadeOut(0.15)])
            .with_position("center")
    )
    return anim

def emoji_burst(size, t: float, dur: float = 0.6):
    pngs = list(EMOJI_DIR.glob("*.png"))
    if not pngs:
        return None
    img = ImageClip(random.choice(pngs)).with_duration(dur)
    start_pos = (
        random.randint(-100, size[1] // 2),
        random.randint(size[0] // 4, 3 * size[0] // 4),
    )
    end_pos = ("center", "center")
    return (
        img.with_effects([Resize(0.35)])
            .with_start(t)
            .with_position(
                lambda τ: (
                    start_pos[0]
                    + (τ / dur) * (end_pos[0] - start_pos[0])
                    if isinstance(end_pos[0], int)
                    else "center",
                    start_pos[1] - (τ / dur) * (start_pos[1] - 50),
                )
            )
            .with_effects([FadeOut(0.2)])
    )

# ───────────── Main routine ────────────────────
def build_interrupt_layers(
    base_clip: VideoFileClip,
    beats: List[Dict],
    word_timings: List[Dict],
) -> List:
    layers: List = [base_clip]
    last_effect_t = -COOLDOWN_SECONDS

    for beat in beats:
        btype = beat.get("type", "hook")
        effect = random.choice(EFFECTS.get(btype, ["zoom_punch"]))
        kw = beat.get("keyword", "")
        # Prefer exact word timestamp; else use provided t_ms
        t = find_word_time(word_timings, kw) if kw else None
        if t is None:
            t = float(beat.get("t_ms", 0)) / 1000.0
        # Cool-down guard
        if t - last_effect_t < COOLDOWN_SECONDS:
            continue
        last_effect_t = t

        if effect == "zoom_punch":
            layers.append(zoom_punch(base_clip, t))
        elif effect == "color_flash":
            layers.append(color_flash(base_clip.size, t))
        elif effect == "word_pop":
            layers.append(word_pop(kw or "!", t))
        elif effect == "emoji_burst":
            eclip = emoji_burst(base_clip.size, t)
            if eclip:
                layers.append(eclip)

    return layers

def compose(manifest_path: Path, out_name="final_with_fx.mp4"):
    man = load_manifest(manifest_path)
    beats = json.loads(man["beats"].read_text())
    words = load_word_timings(man["captions"])

    print("🎬  Loading base video…")
    base = VideoFileClip(str(man["avatar"]))

    # ensure original audio (voice) is preserved
    if base.audio is None and man["audio"].exists():
        base = base.with_audio(AudioFileClip(str(man["audio"])))   # v2: with_audio() :contentReference[oaicite:0]{index=0}

    layers = build_interrupt_layers(base, beats, words)
    final = CompositeVideoClip(layers)
    final = final.resized(height=1920)           # v2: .resized()
    final = final.with_position("center")
    out_path = manifest_path.parent / out_name
    print("🚀  Rendering with effects →", out_path)
    final.write_videofile(
        str(out_path),
        codec="libx264",
        audio_codec="aac",
        fps=base.fps or 30,
        preset="medium",
    )
    print("✅  Done")

# ───────────────────────────────────────────────
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest", help="Path to manifest.json")
    ap.add_argument("--out", default="final_with_fx.mp4")
    args = ap.parse_args()
    compose(Path(args.manifest).expanduser().resolve(), args.out)

if __name__ == "__main__":
    main()