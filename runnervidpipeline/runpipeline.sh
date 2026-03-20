#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

###############################################################################
# Unified pipeline runner:  ScriptGen → OpenVoice → SadTalker → Alignment → FX
###############################################################################

# ───── CLI parsing ───────────────────────────────────────────────────────────
SCRIPT_FILE=""   # --script
INLINE_TEXT=""   # --text
AVATAR=""        # --avatar  (required)
REF_WAV=""       # --ref-wav
SEED_YOUTUBE=${SEED_YOUTUBE:-0}
YT_REGION="US"
YT_TOP=1             # default fallback pick (1-based)
YT_SHOW=6            # how many to display in the menu
YT_PICK=""           # override the choice non-interactively (1-based)
AB_HOOKS=0           # --ab-hooks N  (0 = disabled, else cap to first N in hooks.json)
PATTERN_FLASH_MS=90  # --flash-ms (override flash length)
BYPASS_SCRIPTGEN=0   # --bypass-scriptgen (skip OpenRouter/ScriptGen)

while [[ $# -gt 0 ]]; do
   case "$1" in
     --script)      SCRIPT_FILE="$2"; shift 2 ;;
     --text)        INLINE_TEXT="$2"; shift 2 ;;
     --avatar)      AVATAR="$2"; shift 2 ;;
     --ref-wav)     REF_WAV="$2"; shift 2 ;;
     --workdir)     WORKDIR="$2"; shift 2 ;;
     --seed-youtube) SEED_YOUTUBE=1; shift ;;
     --yt-region)   YT_REGION="$2"; shift 2 ;;
     --yt-top)      YT_TOP="$2"; shift 2 ;;
     --yt-show)     YT_SHOW="$2"; shift 2 ;;
     --yt-pick)     YT_PICK="$2"; shift 2 ;;
     --ab-hooks)    AB_HOOKS="$2"; shift 2 ;;
     --flash-ms)    PATTERN_FLASH_MS="$2"; shift 2 ;;
     --bypass-scriptgen) BYPASS_SCRIPTGEN=1; shift ;;

     -h|--help)     grep '^#' "$0" | cut -c4-; exit 0 ;;
     *) echo "❌ Unknown flag: $1"; exit 1 ;;
   esac
done
[[ -z "$AVATAR" ]] && { echo "❌  --avatar is required"; exit 1; }

# Allow seeding path in place of --script/--text
if [[ "$SEED_YOUTUBE" -eq 0 ]]; then
  [[ -n "$SCRIPT_FILE" || -n "$INLINE_TEXT" ]] || {
    echo "❌  Provide --script or --text (or use --seed-youtube)"; exit 1; }
fi

WORKDIR="${WORKDIR:-$(pwd)/work/$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$WORKDIR"

# ───── Project roots (env-overridable; sensible repo-local defaults) ────────
RUNNER_HOME="$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$RUNNER_HOME/.." && pwd)}"
OPENVOICE_HOME="${OPENVOICE_HOME:-$PROJECT_ROOT/pipeline_openvoice}"
CAPTIONS_HOME="${CAPTIONS_HOME:-$PROJECT_ROOT/Captions_pipeline}"
SADTALKER_HOME="${SADTALKER_HOME:-$PROJECT_ROOT/pipeline_sadtalker}"
SCRIPTGEN_HOME="${SCRIPTGEN_HOME:-$PROJECT_ROOT/ScriptGen_Pipeline}"
COMPOSITOR_HOME="${COMPOSITOR_HOME:-$PROJECT_ROOT/PatternInterrupts_Pipeline}"
ALIGN_SCRIPT="$CAPTIONS_HOME/align.py"
FLATTEN_SCRIPT="$CAPTIONS_HOME/syncmap.py"
YOUTUBE_HOME="${YOUTUBE_HOME:-$PROJECT_ROOT/VidFinder_Pipeline}"
WHISPERX_HOME="${WHISPERX_HOME:-$PROJECT_ROOT/pipelinewhisperx}"
pick_python() {
  local default_path="$1"
  shift
  local candidate=""
  for candidate in "$default_path" "$@"; do
    [[ -n "$candidate" ]] || continue
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

OPENVOICE_PY="${OPENVOICE_PY:-$(pick_python "$OPENVOICE_HOME/.venv/bin/python" "${VIRTUAL_ENV:-}/bin/python" "$PROJECT_ROOT/.venv/bin/python" "$(command -v python3 || true)" "$(command -v python || true)" || true)}"
CAPTIONS_PY="${CAPTIONS_PY:-$(pick_python "$CAPTIONS_HOME/.venv/bin/python" "${VIRTUAL_ENV:-}/bin/python" "$PROJECT_ROOT/.venv/bin/python" "$(command -v python3 || true)" "$(command -v python || true)" || true)}"
SADTALKER_PY="${SADTALKER_PY:-$(pick_python "$SADTALKER_HOME/.venv/bin/python" "${VIRTUAL_ENV:-}/bin/python" "$PROJECT_ROOT/.venv/bin/python" "$(command -v python3 || true)" "$(command -v python || true)" || true)}"
COMPOSITOR_PY="${COMPOSITOR_PY:-$(pick_python "$COMPOSITOR_HOME/.venv/bin/python" "${VIRTUAL_ENV:-}/bin/python" "$PROJECT_ROOT/.venv/bin/python" "$(command -v python3 || true)" "$(command -v python || true)" || true)}"
SCRIPTGEN_PY="${SCRIPTGEN_PY:-$(pick_python "$SCRIPTGEN_HOME/.venv/bin/python" "${VIRTUAL_ENV:-}/bin/python" "$PROJECT_ROOT/.venv/bin/python" "$(command -v python3 || true)" "$(command -v python || true)" || true)}"
YOUTUBE_PY="${YOUTUBE_PY:-$(pick_python "$YOUTUBE_HOME/.venv/bin/python" "${VIRTUAL_ENV:-}/bin/python" "$PROJECT_ROOT/.venv/bin/python" "$(command -v python3 || true)" "$(command -v python || true)" || true)}"
WHISPERX_PY="${WHISPERX_PY:-$(pick_python "$WHISPERX_HOME/.venv/bin/python" "${VIRTUAL_ENV:-}/bin/python" "$PROJECT_ROOT/.venv/bin/python" "$(command -v python3 || true)" "$(command -v python || true)" || true)}"

[[ -x "$OPENVOICE_PY" ]] || {
  echo "❌  OpenVoice python not found: $OPENVOICE_PY"
  echo "   Tried: $OPENVOICE_HOME/.venv/bin/python, \$VIRTUAL_ENV/bin/python, $PROJECT_ROOT/.venv/bin/python, python3, python"
  echo "   Set OPENVOICE_PY explicitly. Example:"
  echo "   export OPENVOICE_PY=\"/absolute/path/to/python\""
  exit 1
}
[[ -x "$SADTALKER_PY" ]] || {
  echo "❌  SadTalker python not found: $SADTALKER_PY"
  echo "   Set SADTALKER_PY or SADTALKER_HOME."
  exit 1
}
[[ -x "$CAPTIONS_PY"  ]] || {
  echo "❌  Captions python not found: $CAPTIONS_PY"
  echo "   Set CAPTIONS_PY or CAPTIONS_HOME."
  exit 1
}
[[ -f "$ALIGN_SCRIPT"  ]] || { echo "❌  align.py not found at $ALIGN_SCRIPT"; exit 1; }
[[ -f "$FLATTEN_SCRIPT" ]] || { echo "❌  syncmap.py not found at $FLATTEN_SCRIPT"; exit 1; }

# ───── Helper ---------------------------------------------------------------
# it takes the command I run in the cli and runs it
run () { local exe="$1"; shift; printf '+ %q ' "$exe" "$@"; printf '\n'; "$exe" "$@"; }

# ───── Compositor env sanity -------------------------------------------------
echo "🧪  Verifying compositor environment"
run "$COMPOSITOR_PY" - <<'PY'
import sys
print("Interpreter:", sys.executable)
try:
    import moviepy
    print("moviepy OK:", getattr(moviepy, "__version__", "unknown"))
except Exception as e:
    print("moviepy import FAILED:", e)
    raise
PY

# ───── Font sanity (fail-fast) ───────────────────────────────────────────────
# Keep this directory CLEAN: only .ttf/.otf inside
FONTS_DIR="${FONTS_DIR:-$RUNNER_HOME/fonts}"
CAPTION_FONT_FILE="${CAPTION_FONT_FILE:-$FONTS_DIR/TikTokSans_24pt_Expanded-Black.ttf}"
CAPTION_FONT_NAME="${CAPTION_FONT_NAME:-}"             # e.g., TikTok Sans 24pt Expanded Black
CAPTION_FONT_POSTSCRIPT="${CAPTION_FONT_POSTSCRIPT:-}" # e.g., TikTokSans24ptExpanded-Black

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

# Fallback defaults if tools missing
CAPTION_FONT_NAME="${CAPTION_FONT_NAME:-TikTok Sans 24pt Expanded Black}"
CAPTION_FONT_POSTSCRIPT="${CAPTION_FONT_POSTSCRIPT:-TikTokSans24ptExpanded-Black}"

echo "🔤  Font Full: $CAPTION_FONT_NAME  | PS: $CAPTION_FONT_POSTSCRIPT"
echo "📁  fontsdir:  $FONTS_DIR"

# Build unescaped & escaped ASS force_style (for SRT fallback)
ASS_STYLE_RAW="Fontname=${CAPTION_FONT_NAME},Fontsize=28,PrimaryColour=&H00FFFFFF&,OutlineColour=&H00000000&,BorderStyle=1,Outline=2,Shadow=1"
# Escape chars that break ffmpeg filtergraph: \ : , [ ], this ensures it interprets them as text
ASS_STYLE_ESCAPED="$(printf '%s' "$ASS_STYLE_RAW" \
  | sed -e 's/\\/\\\\/g' -e 's/:/\\:/g' -e 's/,/\\,/g' -e 's/\[/\\[/g' -e 's/\]/\\]/g')"

# Probe ffmpeg/libass will select the desired font
mkdir -p "$WORKDIR"
PROBE_SRT="$WORKDIR/.font_probe.srt"
cat > "$PROBE_SRT" <<'SRT'
1
00:00:00,000 --> 00:00:00,100
probe
SRT
PROBE_LOG="$WORKDIR/.font_probe.log"
set +e
ffmpeg -hide_banner -loglevel verbose \
  -f lavfi -i color=c=black:s=320x180:d=0.2 \
  -vf "subtitles=${PROBE_SRT}:fontsdir=${FONTS_DIR}:force_style=${ASS_STYLE_ESCAPED}" \
  -t 0.2 -f null - >"$PROBE_LOG" 2>&1
set -e
if ! (grep -qi "fontselect:.*${CAPTION_FONT_NAME}" "$PROBE_LOG" || \
      grep -qi "fontselect:.*${CAPTION_FONT_POSTSCRIPT}" "$PROBE_LOG"); then
  echo "❌ Font probe failed: see $PROBE_LOG"; exit 1
fi
echo "✅ Font probe ok."

# ───── (-1) Optional: discover & pick a YouTube video, then build summary prompt ──
if [[ "$SEED_YOUTUBE" -eq 1 ]]; then
  echo "🔎  Discovering YouTube (region=${YT_REGION})"
  YT_HELPER="$YOUTUBE_HOME/yt_trending.py"
  [[ -f "$YT_HELPER" ]] || { echo "❌ yt_trending.py not found at $YT_HELPER"; exit 1; }

  export RUNNER_HOME WORKDIR YT_REGION YT_TOP YT_SHOW YT_PICK YOUTUBE_HOME

  # 1) Discover + pick (no transcript here)
  run "$YOUTUBE_PY" - <<'PY'
import os, sys, json
from pathlib import Path
sys.path.append(os.environ["YOUTUBE_HOME"])
import yt_trending as yt

workdir   = Path(os.environ["WORKDIR"])
region    = os.environ.get("YT_REGION","US")
yt_show   = max(1, int(os.environ.get("YT_SHOW","6")))
yt_top    = max(1, int(os.environ.get("YT_TOP","1")))
yt_pick   = os.environ.get("YT_PICK","").strip()

hits = yt.discover_longform_semiviral(region=region)
if not hits:
    raise SystemExit("No semi-viral long-form videos found.")

print("\n=== SEMI-VIRAL LONG-FORM (ranked by views/hour) ===")
for i, h in enumerate(hits[:yt_show], 1):
    print(f"{i:>2}. {h['title'][:72]}  | {h['length']}  | VPH={h['views/h']:.0f}  | {h['url']}")

idx = None
if yt_pick:
    try: idx = int(yt_pick)
    except: idx = None
if idx is None and sys.stdin.isatty():
    raw = input(f"Pick 1–{min(yt_show, len(hits))} (Enter={yt_top}): ").strip()
    idx = int(raw) if raw else yt_top
if idx is None: idx = yt_top
idx = max(1, min(idx, len(hits)))
pick = hits[idx-1]

workdir.mkdir(parents=True, exist_ok=True)
(workdir/"seed_meta.json").write_text(json.dumps({"pick":pick}, indent=2), encoding="utf-8")

print(f"\n✔ Picked: {pick['title']}")
print(f"   URL:   {pick['url']}")
PY

  # 2) Run WhisperX on the picked URL → transcript files
  PICK_URL="$("$YOUTUBE_PY" - "$WORKDIR/seed_meta.json" <<'PY'
import json, sys
from pathlib import Path
p = Path(sys.argv[1])
data = json.loads(p.read_text())
print(data["pick"]["url"])
PY
)"
  echo "PICK_URL=$PICK_URL"
  echo "🧠  WhisperX transcribing: $PICK_URL"
  SEED_DIR="$WORKDIR/seed"
  mkdir -p "$SEED_DIR"
  [[ -x "$WHISPERX_PY" ]] || { echo "❌ WhisperX Python not found at $WHISPERX_PY"; exit 1; }
  [[ -f "$WHISPERX_HOME/src/whisperx_runner.py" ]] || { echo "❌ whisperx_runner.py not found in $WHISPERX_HOME"; exit 1; }
  run "$WHISPERX_PY" "$WHISPERX_HOME/src/whisperx_runner.py" \
      --url "$PICK_URL" \
      --out "$SEED_DIR" \
      --model-size medium \
      --lang en \
      --batch-size 16

  # 3) Build the ScriptGen input prompt from the transcript
  SEED_OUT="$SEED_DIR/transcript.txt"
  [[ -s "$SEED_OUT" ]] || { echo "❌ WhisperX produced no transcript at $SEED_OUT"; exit 1; }
  INLINE_TEXT=$'Summarize and rewrite a tight, high-retention on-camera script (45–60s) for a general audience.\n'
  INLINE_TEXT+=$'Make it punchy, plain-language, with a hook in line 1 and a crisp CTA in the last line.\n\n'
  INLINE_TEXT+=$'SOURCE TRANSCRIPT:\n\n'
  INLINE_TEXT+="$(cat "$SEED_OUT")"
  SCRIPT_FILE=""
fi

# ───── 0) Script/Beats → (ScriptGen OR bypass) ──────────────────────────────
FINAL_SCRIPT="$WORKDIR/script.txt"
BEATS_OUT="$WORKDIR/beats.json"

if [[ "$BYPASS_SCRIPTGEN" -eq 1 ]]; then
  echo "🧯  Bypassing ScriptGen/OpenRouter (using provided --script/--text)"

  # 1) Create script.txt from --script or --text
  if [[ -n "${SCRIPT_FILE:-}" ]]; then
    [[ -f "$SCRIPT_FILE" ]] || { echo "❌  --script not found: $SCRIPT_FILE"; exit 1; }
    cp "$SCRIPT_FILE" "$FINAL_SCRIPT"
  else
    [[ -n "${INLINE_TEXT:-}" ]] || { echo "❌  Provide --script or --text when bypassing ScriptGen"; exit 1; }
    printf "%s\n" "$INLINE_TEXT" > "$FINAL_SCRIPT"
  fi

  # 2) Make a simple beats.json (regular beats every ~1.2s)
  export WORKDIR
  run "$COMPOSITOR_PY" - <<'PY'
import json, os, re
from pathlib import Path

workdir = Path(os.environ["WORKDIR"])
script = (workdir/"script.txt").read_text(encoding="utf-8").strip()

# rough duration estimate: 150 wpm
words = re.findall(r"\S+", script)
wpm = 150.0
duration = max(6.0, (len(words) / wpm) * 60.0)

# beats every 1.2s
step = 1.2
beats = [{"t": round(i*step, 2)} for i in range(int(duration//step) + 1)]

(workdir/"beats.json").write_text(json.dumps(beats, indent=2), encoding="utf-8")
print(f"✅ Wrote beats.json with {len(beats)} beats, est duration ~{duration:.1f}s")
PY

else
  echo "📝  Generating script & beats (ScriptGen)"
  [[ -x "$SCRIPTGEN_PY" ]] || {
    echo "❌  ScriptGen python not found: $SCRIPTGEN_PY"
    echo "   Set SCRIPTGEN_PY explicitly."
    exit 1
  }
  export PYTHONPATH="${PYTHONPATH:-}:$PROJECT_ROOT"
  SCRIPTGEN_PARENT="$(dirname "$SCRIPTGEN_HOME")"
  export PYTHONPATH="${PYTHONPATH:-}:$SCRIPTGEN_PARENT"
  export INLINE_TEXT="${INLINE_TEXT:-}"
  export WORKDIR

  run "$SCRIPTGEN_PY" - <<'PY'
import os
from pathlib import Path
from ScriptGen_Pipeline.ScriptGen import generate_video_assets

input_text = os.environ.get("INLINE_TEXT", "").strip()
workdir = Path(os.environ["WORKDIR"])
print(f"📂  Workdir: {workdir}")
print("📝  Generating script & beats")
generate_video_assets(input_text, "Generated Video", workdir)
PY
fi

# sanity check outputs needed downstream
[[ -s "$FINAL_SCRIPT" ]] || { echo "❌ script.txt missing/empty at $FINAL_SCRIPT"; exit 1; }
[[ -s "$BEATS_OUT"    ]] || { echo "❌ beats.json missing/empty at $BEATS_OUT"; exit 1; }

# ───── 0.5) Hook A/B branch (short-circuits the rest) ───────────────────────
if [[ "${AB_HOOKS:-0}" -gt 0 ]]; then
  echo "🪄  Hook A/B mode: first ${AB_HOOKS} hooks"
  run "$OPENVOICE_PY" - <<'PY'
# no-op; this keeps your logging format consistent before handing off
PY

  run "/usr/bin/env" python3 "$HOOKAB_PY" \
      --workdir "$WORKDIR" \
      --avatar "$AVATAR" \
      --script "$WORKDIR/script.txt" \
      --hooks-json "$WORKDIR/hooks.json" \
      --num-hooks "$AB_HOOKS" \
      --ref-wav "${REF_WAV:-}" \
      --openvoice-py "$OPENVOICE_PY" \
      --openvoice-home "$OPENVOICE_HOME" \
      --sadtalker-py "$SADTALKER_PY" \
      --sadtalker-home "$SADTALKER_HOME" \
      --captions-py "$CAPTIONS_PY" \
      --align-script "$ALIGN_SCRIPT" \
      --fonts-dir "$FONTS_DIR" \
      --caption-font-full "$CAPTION_FONT_NAME" \
      --flash-ms "$PATTERN_FLASH_MS"

  echo -e "\n🎬  A/B assets ready in $WORKDIR"
  ls -1 "$WORKDIR"/final_H*.mp4 2>/dev/null || true
  exit 0
fi

# ───── 1) OpenVoice → voice.wav ─────────────────────────────────────────────
echo "🗣️   OpenVoice → synthesising voice"
VOICE_OUT="$WORKDIR/voice.wav"

OPENVOICE_ARGS=(
  "$OPENVOICE_HOME/src/openvoice.py"
  --out "$VOICE_OUT"
  --checkpoint-path "$OPENVOICE_HOME/checkpoints"
  --script "$FINAL_SCRIPT"
)
[[ -n "$REF_WAV" ]] && OPENVOICE_ARGS+=( --reference "$REF_WAV" ) || OPENVOICE_ARGS+=( --speaker EN-Default )
run "$OPENVOICE_PY" "${OPENVOICE_ARGS[@]}"

# ───── 2) Alignment → captions_{srt,json} ───────────────────────────────────
echo "📝  Aligning captions"
CAPT_SRT="$WORKDIR/captions.srt"
CAPT_SYNCMAP="$WORKDIR/captions_sync.json"
CAPT_WORDS="$WORKDIR/captions_words.json"

run "$CAPTIONS_PY" "$ALIGN_SCRIPT" \
     --wav    "$VOICE_OUT" \
     --script "$FINAL_SCRIPT" \
     --srt    "$CAPT_SRT" \
     --json   "$CAPT_SYNCMAP"

# Flatten sync map (use captions venv)
run "$CAPTIONS_PY" "$FLATTEN_SCRIPT" \
     --in  "$CAPT_SYNCMAP" \
     --out "$CAPT_WORDS"

# ───── 2.5) Build ASS (karaoke per-word with color) ─────────────────────────
ASS_OUT="$WORKDIR/captions_highlight.ass"
echo "🎤  Generating karaoke ASS → $ASS_OUT"

# export so Python can read while we single-quote the heredoc
export WORKDIR CAPTION_FONT_NAME CAPTION_FONT_SIZE

"$CAPTIONS_PY" - <<'PY'
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
; generated by unified pipeline
ScriptType: v4.00+
PlayResX: 1080
PlayResY: 1920
WrapStyle: 2
ScaledBorderAndShadow: yes

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: CapHi,{fontname},{fontsize},&H00FFFFFF,&H00FFFFFF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,3,0,2,60,60,90,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
rows = [header]

# Color behavior: white → turns purple during highlight → back to white
HIGHLIGHT_PURPLE = "&HFF00FF&"   # \1c while active
UNFILLED_WHITE   = "&H00FFFFFF&" # \2c before highlight
word_counter = 0

for line in lines:
    start = max(0.0, line[0]["s"])
    end   = max(start + 0.01, line[-1]["e"])

    # \k durations (centiseconds) and reconcile with event length
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
            chunks.append("{\\1c%s\\2c%s\\k%d}%s{\\rCapHi} " % (HIGHLIGHT_PURPLE, UNFILLED_WHITE, kcs, txt))
        else:
            chunks.append("{\\k%d}%s " % (kcs, txt))
    text = "".join(chunks).rstrip()
    rows.append(f"Dialogue: 0,{to_ass_time(start)},{to_ass_time(end)},CapHi,,0,0,0,,{text}\n")

ass_out.write_text("".join(rows), encoding="utf-8")
print(f"Wrote: {ass_out}")
PY

# ───── 3) SadTalker → avatar.mp4 ────────────────────────────────────────────
MARKER="$WORKDIR/.sadtalker_start"; : > "$MARKER"   # before running SadTalker

START_TS=$(date +%s)

rm -f "$WORKDIR"/video/*.mp4 2>/dev/null || true
echo "🎭  SadTalker → generating talking head"
cd "$SADTALKER_HOME"
run "$SADTALKER_PY" \
    src/sadtalker.py \
    --audio  "$VOICE_OUT" \
    --avatar "$AVATAR" \
    --out    "$WORKDIR/video"

FINAL_MP4=$(
  find "$WORKDIR/video" -type f -name '*.mp4' -newer "$MARKER" -print0 \
  | xargs -0 ls -t 2>/dev/null | head -n1
)
[[ -n "$FINAL_MP4" ]] || { echo "❌ No new video produced by SadTalker"; exit 1; }

# ───── 4) (No pre-burn) — captions will be burned AFTER compositor ──────────

# ───── 5) Manifest for compositor ───────────────────────────────────────────
echo "📦  Writing manifest.json"
AVATAR_CLIP="video/$(basename "$FINAL_MP4")"   # keep relative to $WORKDIR

# sanity check
[[ -f "$WORKDIR/$AVATAR_CLIP" ]] || {
  echo "❌ Avatar clip not found at $WORKDIR/$AVATAR_CLIP"
  echo "   Available in $WORKDIR/video:"
  ls -l "$WORKDIR/video" || true
  exit 1
}

cat > "$WORKDIR/manifest.json" <<EOF
{
  "audio": "voice.wav",
  "avatar": "$AVATAR_CLIP",
  "captions": "captions_words.json",
  "beats": "beats.json"
}
EOF
[[ -x "$COMPOSITOR_PY" ]] || { echo "❌  Compositor venv not found"; exit 1; }
[[ -f "$COMPOSITOR_HOME/compositor.py" ]] || { echo "❌  compositor.py not found"; exit 1; }

# ───── 6) Pattern Interrupts with compositor.py ─────────────────────────────
rm -f "$WORKDIR/final_with_fx.mp4"

echo "🎨  Applying pattern-interrupt effects"
COMPOSITOR_PATH="$COMPOSITOR_HOME/compositor.py"
FINAL_FX="$WORKDIR/final_with_fx.mp4"

run "$COMPOSITOR_PY" "$COMPOSITOR_PATH" "$WORKDIR/manifest.json" --out "$FINAL_FX"

# ───── 7) Burn captions (ASS with highlights preferred; fallback to SRT) ────
# Take VIDEO from compositor/SadTalker and AUDIO from the freshly-synthesized voice.wav.
[[ -s "$FINAL_FX" ]] || { echo "❌ Compositor failed to produce FX video"; exit 1; }
INPUT_FOR_BURN="$FINAL_FX"
[[ -f "$INPUT_FOR_BURN" ]] || INPUT_FOR_BURN="$FINAL_MP4"
AUDIO_FOR_BURN="$VOICE_OUT"

ASS_HILITE="$WORKDIR/captions_highlight.ass"

if [[ -f "$ASS_HILITE" ]]; then
  echo "🔥  Burning ASS captions with highlights (mapping audio from voice.wav)"
  ffmpeg -y -loglevel verbose \
    -i "$INPUT_FOR_BURN" \
    -i "$AUDIO_FOR_BURN" \
    -vf "ass=${ASS_HILITE}:fontsdir=${FONTS_DIR}" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -c:a aac -b:a 192k -shortest -movflags +faststart \
    "$WORKDIR/final_with_captions.mp4"
else
  echo "ℹ️  No captions_highlight.ass found; burning SRT with style (mapping audio from voice.wav)"
  BURN_LOG="$WORKDIR/captions_burn.log"
  ffmpeg -y -loglevel verbose \
    -i "$INPUT_FOR_BURN" \
    -i "$AUDIO_FOR_BURN" \
    -vf "subtitles=${CAPT_SRT}:fontsdir=${FONTS_DIR}:force_style=${ASS_STYLE_ESCAPED}" \
    -map 0:v:0 -map 1:a:0 \
    -c:v libx264 -c:a aac -b:a 192k -shortest -movflags +faststart \
    "$WORKDIR/final_with_captions.mp4" \
    2> "$BURN_LOG" || { echo "❌ SRT burn failed; see $BURN_LOG"; exit 1; }
fi

# ───── Summary ──────────────────────────────────────────────────────────────
echo -e "\n🎬  Assets ready in $WORKDIR"
ls -1 "$WORKDIR"/{script.txt,beats.json,voice.wav,captions_words.json,manifest.json} 2>/dev/null
echo -e "\n🎬  Outputs"
ls -1 "$WORKDIR"/{final_with_fx.mp4,final_with_captions.mp4} 2>/dev/null
