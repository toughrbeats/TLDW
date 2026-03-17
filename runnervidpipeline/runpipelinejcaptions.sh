#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Captions preview loop (no SadTalker, no ScriptGen, reuses voice):
#    script.txt + voice.wav  →  align  →  SRT + words.json  →  ASS (karaoke)
#    →  quick 9:16 preview (burned ASS)
###############################################################################

# ───── CLI ──────────────────────────────────────────────────────────────────
WORKDIR="$(pwd)/work"
REF_WAV=""            # only used if you ever force-regenerate voice (off by default)
FORCE_VOICE=0         # --regen-voice (normally 0; we reuse voice.wav)
BG_SPEC="color=c=black:s=1080x1920:r=30"  # 9:16 by default
HELP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workdir)     WORKDIR="$2"; shift 2 ;;
    --ref-wav)     REF_WAV="$2"; shift 2 ;;
    --regen-voice) FORCE_VOICE=1; shift 1 ;;
    --bg)          BG_SPEC="$2"; shift 2 ;;
    -h|--help)     HELP=1; shift 1 ;;
    *) echo "❌ Unknown flag: $1"; exit 1 ;;
  esac
done

if [[ $HELP -eq 1 ]]; then
  grep '^#' "$0" | cut -c4-
  cat <<'TXT'

Usage:
  # Fastest loop (reuse voice): realign + regenerate ASS + burn preview
  ./run_caps_preview.sh

  # If you ever need to rebuild voice from script.txt (optional)
  ./run_caps_preview.sh --regen-voice [--ref-wav /path/to/ref.wav]

  # Switch preview canvas (e.g., 16:9)
  ./run_caps_preview.sh --bg "color=c=black:s=1920x1080:r=30"
TXT
  exit 0
fi

mkdir -p "$WORKDIR"
echo "📂  Workdir: $WORKDIR"

# ───── Project roots (edit if paths differ) ─────────────────────────────────
OPENVOICE_HOME="/Users/raj/PycharmProjects/pipeline_openvoice"
CAPTIONS_HOME="/Users/raj/PycharmProjects/Captions_pipeline"
SCRIPTGEN_HOME="/Users/raj/PycharmProjects/ScriptGen_Pipeline"  # not used here; kept for PYTHONPATH
CAPTIONS_PY="$CAPTIONS_HOME/.venv/bin/python"
OPENVOICE_PY="$OPENVOICE_HOME/.venv/bin/python"
ALIGN_SCRIPT="$CAPTIONS_HOME/align.py"
FLATTEN_SCRIPT="$CAPTIONS_HOME/syncmap.py"

[[ -f "$WORKDIR/script.txt" ]] || { echo "❌ Missing $WORKDIR/script.txt"; exit 1; }
[[ -x "$CAPTIONS_PY" ]] || { echo "❌ captions venv python not found: $CAPTIONS_PY"; exit 1; }
[[ -f "$ALIGN_SCRIPT"  ]] || { echo "❌ align.py not found: $ALIGN_SCRIPT"; exit 1; }
[[ -f "$FLATTEN_SCRIPT" ]] || { echo "❌ syncmap.py not found: $FLATTEN_SCRIPT"; exit 1; }

# ───── Fonts (fail-fast) ────────────────────────────────────────────────────
FONTS_DIR="${FONTS_DIR:-/Users/raj/PycharmProjects/runnervidpipeline/fonts}"
CAPTION_FONT_FILE="${CAPTION_FONT_FILE:-$FONTS_DIR/TikTokSans_24pt_Expanded-Black.ttf}"
CAPTION_FONT_NAME="${CAPTION_FONT_NAME:-}"
CAPTION_FONT_POSTSCRIPT="${CAPTION_FONT_POSTSCRIPT:-}"
CAPTION_FONT_SIZE="${CAPTION_FONT_SIZE:-54}"   # bigger for 1080x1920

[[ -d "$FONTS_DIR" ]] || { echo "❌ FONTS_DIR not found: $FONTS_DIR"; exit 1; }
if [[ ! -f "$CAPTION_FONT_FILE" && ( -z "$CAPTION_FONT_NAME" || -z "$CAPTION_FONT_POSTSCRIPT" ) ]]; then
  echo "❌ No font at $CAPTION_FONT_FILE and CAPTION_FONT_NAME/POSTSCRIPT not set."; exit 1
fi

# Try to extract names if not provided
if [[ -z "$CAPTION_FONT_NAME" || -z "$CAPTION_FONT_POSTSCRIPT" ]]; then
  if command -v fc-scan >/dev/null 2>&1; then
    CAPTION_FONT_NAME="${CAPTION_FONT_NAME:-$(fc-scan --format '%{fullname}\n' "$CAPTION_FONT_FILE" | head -n1)}"
    CAPTION_FONT_POSTSCRIPT="${CAPTION_FONT_POSTSCRIPT:-$(fc-scan --format '%{postscriptname}\n' "$CAPTION_FONT_FILE" | head -n1)}"
  elif command -v otfinfo >/dev/null 2>&1; then
    CAPTION_FONT_NAME="${CAPTION_FONT_NAME:-$(otfinfo -i "$CAPTION_FONT_FILE" | awk -F': ' '/^Full name:/ {print $2; exit}')}"
    CAPTION_FONT_POSTSCRIPT="${CAPTION_FONT_POSTSCRIPT:-$(otfinfo -i "$CAPTION_FONT_FILE" | awk -F': ' '/^PostScript name:/ {print $2; exit}')}"
  fi
fi
CAPTION_FONT_NAME="${CAPTION_FONT_NAME:-TikTok Sans 24pt Expanded Black}"
CAPTION_FONT_POSTSCRIPT="${CAPTION_FONT_POSTSCRIPT:-TikTokSans24ptExpanded-Black}"

echo "🔤  Font: $CAPTION_FONT_NAME (PS: $CAPTION_FONT_POSTSCRIPT)  size=${CAPTION_FONT_SIZE}"
echo "📁  fontsdir: $FONTS_DIR"

# Build SRT force_style (for fallback use)
ASS_STYLE_RAW="Fontname=${CAPTION_FONT_NAME},Fontsize=${CAPTION_FONT_SIZE},PrimaryColour=&H00FFFFFF&,SecondaryColour=&H00666666&,OutlineColour=&H00000000&,BackColour=&H64000000&,BorderStyle=1,Outline=3,Shadow=0"
ASS_STYLE_ESCAPED="$(printf '%s' "$ASS_STYLE_RAW" \
  | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g' -e 's/,/\\,/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g')"

# ───── Helper ---------------------------------------------------------------
run () { local exe="$1"; shift; printf '+ %q ' "$exe" "$@"; printf '\n'; "$exe" "$@"; }

# ───── Voice (default: reuse) ───────────────────────────────────────────────
VOICE_OUT="$WORKDIR/voice.wav"
if [[ $FORCE_VOICE -eq 1 ]]; then
  echo "🗣️   Regenerating voice via OpenVoice"
  [[ -x "$OPENVOICE_PY" ]] || { echo "❌ OpenVoice venv python not found: $OPENVOICE_PY"; exit 1; }
  OPENVOICE_ARGS=(
    "$OPENVOICE_HOME/src/openvoice.py"
    --out "$VOICE_OUT"
    --checkpoint-path "$OPENVOICE_HOME/checkpoints"
    --script "$WORKDIR/script.txt"
  )
  [[ -n "$REF_WAV" ]] && OPENVOICE_ARGS+=( --reference "$REF_WAV" ) || OPENVOICE_ARGS+=( --speaker default )
  run "$OPENVOICE_PY" "${OPENVOICE_ARGS[@]}"
else
  [[ -f "$VOICE_OUT" ]] || { echo "❌ Missing $VOICE_OUT (add it or run with --regen-voice)"; exit 1; }
  echo "🗣️   Reusing existing voice: $VOICE_OUT"
fi

# ───── Alignment → SRT + words.json ─────────────────────────────────────────
echo "📝  Aligning captions"
CAPT_SRT="$WORKDIR/captions.srt"
CAPT_SYNCMAP="$WORKDIR/captions_sync.json"
CAPT_WORDS="$WORKDIR/captions_words.json"

run "$CAPTIONS_PY" "$ALIGN_SCRIPT" \
     --wav    "$VOICE_OUT" \
     --script "$WORKDIR/script.txt" \
     --srt    "$CAPT_SRT" \
     --json   "$CAPT_SYNCMAP"

run "$CAPTIONS_PY" "$FLATTEN_SCRIPT" \
     --in  "$CAPT_SYNCMAP" \
     --out "$CAPT_WORDS"

# ───── Build ASS (karaoke per-word) from words.json ─────────────────────────
ASS_OUT="$WORKDIR/captions_highlight.ass"
echo "🎤  Generating karaoke ASS → $ASS_OUT"

# Export vars so Python can read them while we single-quote the heredoc
export WORKDIR CAPTION_FONT_NAME CAPTION_FONT_SIZE

run "$CAPTIONS_PY" - <<'PY'
import json, os, re
from pathlib import Path

work = Path(os.environ["WORKDIR"])
words_path = work / "captions_words.json"
ass_out = work / "captions_highlight.ass"

# Load words (supports multiple schemas)
data = json.loads(words_path.read_text(encoding="utf-8"))
words = []
if isinstance(data, dict):
    if "words" in data and isinstance(data["words"], list):
        for w in data["words"]:
            txt = (w.get("word") or w.get("text") or "").strip()
            if not txt: continue
            s = float(w.get("start", 0.0)); e = float(w.get("end", s))
            if e < s: e = s
            words.append({"t": txt, "s": s, "e": e})
    elif "segments" in data:
        for seg in data["segments"]:
            seg_text = (seg.get("text") or "").strip()
            if not seg_text: continue
            s0 = float(seg.get("start", 0.0)); e0 = float(seg.get("end", s0))
            toks = re.findall(r"\S+|\s+", seg_text)
            nonspace = [t for t in toks if not t.isspace()]
            dur = max(0.0, e0 - s0); step = dur / max(1, len(nonspace))
            cur = s0
            for t in toks:
                if t.isspace(): continue
                words.append({"t": t, "s": cur, "e": cur + step}); cur += step
else:
    for w in data:
        if not isinstance(w, dict): continue
        txt = (w.get("word") or "").strip()
        if not txt: continue
        s = float(w.get("start", 0.0)); e = float(w.get("end", s))
        words.append({"t": txt, "s": s, "e": e})

if not words:
    raise SystemExit("No words found in captions_words.json")

# Group words into lines
MAX_CHARS = 44
PAUSE_BREAK = 0.60
lines, cur = [], []
for w in words:
    if not cur:
        cur = [w]; continue
    prev = cur[-1]; gap = w["s"] - prev["e"]
    row_text = " ".join(x["t"] for x in cur)
    if gap > PAUSE_BREAK or (len(row_text) + 1 + len(w["t"]) > MAX_CHARS):
        lines.append(cur); cur = [w]
    else:
        cur.append(w)
if cur: lines.append(cur)

def to_ass_time(t):
    total = int(round(max(0.0, t) * 100))  # centiseconds
    h = total // 360000; total %= 360000
    m = total // 6000;   total %= 6000
    s = total // 100;    cs = total % 100
    return f"{h:d}:{m:02d}:{s:02d}.{cs:02d}"

fontname = os.environ.get("CAPTION_FONT_NAME", "TikTok Sans 24pt Expanded Black")
fontsize = int(os.environ.get("CAPTION_FONT_SIZE", "54"))

header = f"""[Script Info]
; generated by run_caps_preview.sh
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: CapHi,{fontname},{fontsize},&H00FFFFFF,&H00666666,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,0,2,60,60,90,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""

rows = [header]

# Color only the highlight overlay for every 3rd word, during its own \k window
# put near rows = [header]
# color only while the word is highlighted; white before highlight
HIGHLIGHT_PURPLE = "&HFF00FF&"   # primary (filled) during \k
UNFILLED_WHITE   = "&H00FFFFFF&" # secondary (unfilled) before \k
word_counter = 0  # move inside the line-loop if you want per-line reset

for line in lines:
    start = max(0.0, line[0]["s"])
    end   = max(start + 0.01, line[-1]["e"])

    # robust \k durations that match event length
    durs_cs = [max(1, int(round(max(0.0, w["e"] - w["s"]) * 100))) for w in line]
    event_cs = max(1, int(round((end - start) * 100)))
    ksum = sum(durs_cs)
    if ksum != event_cs:
        durs_cs[-1] = max(1, durs_cs[-1] + (event_cs - ksum))

    chunks = []
    for (w, kcs) in zip(line, durs_cs):
        word_counter += 1
        txt = w["t"].replace("{", r"\{").replace("}", r"\}")
        if word_counter % 3 == 0:
            # NOTE the reset: {\rCapHi} (NOT just {\r})
            chunks.append("{\\1c%s\\2c%s\\k%d}%s{\\rCapHi} " % (HIGHLIGHT_PURPLE, UNFILLED_WHITE, kcs, txt))
        else:
            chunks.append("{\\k%d}%s " % (kcs, txt))

    text = "".join(chunks).rstrip()
    rows.append(f"Dialogue: 0,{to_ass_time(start)},{to_ass_time(end)},CapHi,,0,0,0,,{text}\n")

ass_out.write_text("".join(rows), encoding="utf-8")
print(f"Wrote: {ass_out}")
PY

# ───── Quick 9:16 preview with ASS burned ───────────────────────────────────
echo "🎞️  Building preview (ASS karaoke)"
PREVIEW_MP4="$WORKDIR/preview_captions.mp4"
ffmpeg -y -hide_banner -loglevel error \
  -f lavfi -i "$BG_SPEC:d=3600" \
  -i "$VOICE_OUT" \
  -shortest \
  -vf "ass=${ASS_OUT}:fontsdir=${FONTS_DIR}" \
  -c:v libx264 -pix_fmt yuv420p -r 30 \
  -c:a aac -b:a 192k \
  "$PREVIEW_MP4"

echo -e "\n✅  Preview ready: $PREVIEW_MP4"
echo -e "📦  Also wrote:\n - $CAPT_SRT\n - $CAPT_SYNCMAP\n - $CAPT_WORDS\n - $ASS_OUT"
