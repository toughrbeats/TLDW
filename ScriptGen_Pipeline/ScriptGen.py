"""
script_gen.py · generates an engaging YT-style script *and* writes
script.txt + beats.json + hooks.json for the downstream pipeline.

Typical call from your runner:
------------------------------------------------------------------
from script_gen import generate_video_assets
generate_video_assets(
    transcript=transcript_text,
    title=video_title,
    workdir=Path("/abs/path/to/work")
)
------------------------------------------------------------------
If you only want the raw dict (no disk writes), call the lower-level
`generate_video_script()` as before.
"""
from __future__ import annotations
import os, json, time, math
import re

from pathlib import Path
from typing import Dict, Any, List

from dotenv import load_dotenv
import requests
try:
    import tiktoken
except Exception:
    tiktoken = None

# ───────────────────────  ENV  ───────────────────────────────────────────────
load_dotenv()
OPENROUTER_API_KEY = os.getenv("OPENROUTER_API_KEY")
if not OPENROUTER_API_KEY:
    raise EnvironmentError("Missing OPENROUTER_API_KEY")
DEFAULT_MODEL = os.getenv("OPENROUTER_MODEL", "google/gemma-3n-e2b-it:free")

# ───────────────────  Token helper  ─────────────────────────────────────────
def count_tokens(text: str, model: str | None = None) -> int:
    """
    Best-effort token estimate. Falls back gracefully if model isn't known to
    tiktoken. Safe for gating huge transcripts.
    """
    if not text:
        return 0
    if tiktoken is not None:
        enc = None
        try:
            if model:
                enc = tiktoken.encoding_for_model(model)
        except Exception:
            pass
        if enc is None:
            try:
                enc = tiktoken.get_encoding("cl100k_base")
            except Exception:
                enc = None
        if enc is not None:
            try:
                return len(enc.encode(text))
            except Exception:
                pass
    # crude fallback ≈ 0.75 words/token
    return int(len(text.split()) / 0.75)

# ───────────────────  OpenRouter wrapper  ───────────────────────────────────
def _openrouter(messages: List[Dict[str, str]],
                model: str,
                retries: int = 3,
                backoff: float = 1.5) -> Dict[str, Any]:
    url = "https://openrouter.ai/api/v1/chat/completions"
    headers = {
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
        "Content-Type":  "application/json"
    }
    payload = {"model": model, "messages": messages}

    for attempt in range(1, retries + 1):
        r = requests.post(url, headers=headers, json=payload, timeout=90)
        if r.status_code in (429, 503):
            if attempt == retries:
                r.raise_for_status()
            time.sleep(backoff ** attempt)
            continue
        r.raise_for_status()
        return r.json()
    raise RuntimeError("Unreachable OpenRouter call")

# ───────────────────  Sanitizers  ───────────────────────────────────────────
def _sanitize_hooks(hooks: List[str]) -> List[str]:
    out: List[str] = []
    seen = set()
    for h in hooks or []:
        if not isinstance(h, str):
            continue
        s = re.sub(r"\s+", " ", h.strip())
        if not s:
            continue
        if s.lower() in seen:
            continue
        # keep hooks tight; avoid walls of text
        if len(s) > 120:
            s = s[:120].rstrip()
        out.append(s)
        seen.add(s.lower())
        if len(out) >= 5:
            break
    return out

def _sanitize_beats(beats: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    if not isinstance(beats, list):
        return []
    cleaned: List[Dict[str, Any]] = []
    for b in beats:
        if not isinstance(b, dict):
            continue
        t = b.get("t_ms", 0)
        try:
            t = int(round(float(t)))
        except Exception:
            t = 0
        t = max(0, min(60000, t))
        typ = str(b.get("type", "beat")).strip() or "beat"
        kw = str(b.get("keyword", "")).strip()
        cleaned.append({"t_ms": t, "type": typ, "keyword": kw})
    # sort monotonically by time
    cleaned.sort(key=lambda x: x["t_ms"])
    # ensure first beat (if any) is at 0 for hook
    if cleaned:
        cleaned[0]["t_ms"] = 0
    return cleaned

# ───────────────────  Core LLM fn  ───────────────────────────────────────────
def generate_video_script(transcript: str,
                          title: str = "",
                          model: str = DEFAULT_MODEL) -> Dict[str, Any]:
    """
    Returns a dict with keys:
      - "script": <markdown str> (45–60 seconds, on-camera, hook is line 1)
      - "beats":  list[{"t_ms": int,"type": str,"keyword": str}]
      - "hooks":  list[str]  (3–5 alternative first lines for A/B)
    """
    tk = count_tokens(transcript, model)
    if tk > 120_000:
        raise ValueError("Transcript too long for model guard-rail")

    prompt = f"""
You are a viral short-form scriptwriter for YouTube/TikTok.

TASK:
1) Write a 45–60 second *on-camera* script in **punchy plain English**.
   - Line 1 must be a high-gravity HOOK (no emojis/hashtags).
   - Keep sentences tight; prefer active voice; end with a crisp CTA.
   - The script is a rewrite/summary of the source transcript.

2) Produce 3–5 ALTERNATIVE HOOKS (short, 3–12 words each) that could
   replace line 1 while keeping the rest of the body unchanged.
   - Address the viewer ("you"), avoid clickbait clichés, no emojis.

3) Identify key BEATS with start times in milliseconds between 0 and 60000.
   - Assume ~170 WPM.
   - Include at least: "hook" at 0ms and "cta" near the end.
   - Other examples: "setup", "insight", "twist", "example".

OUTPUT:
Return **only** strict JSON (no prose, no markdown fences) like:
{{
  "script": "<markdown string with line breaks>",
  "beats":  [{{"t_ms":0,"type":"hook","keyword":"..."}}, {{ "t_ms": 4200, "type":"insight","keyword":"..."}}, {{ "t_ms": 56000, "type":"cta","keyword":"..."}}],
  "hooks":  ["Alt hook 1", "Alt hook 2", "Alt hook 3"]
}}

Transcript title: "{title}"
Transcript:
\"\"\"{transcript}\"\"\"
""".strip()

    data = _openrouter([{"role": "user", "content": prompt}], model)

    raw = data["choices"][0]["message"]["content"]
    print("=== RAW OUTPUT START ===")
    print(repr(raw))  # Shows whitespace, escape chars
    print("=== RAW OUTPUT END ===")

    if not raw or not raw.strip():
        raise ValueError("LLM returned empty response")

    # If the model returned a dict already, just return it
    if isinstance(raw, dict):
        result = raw
    else:
        raw_stripped = raw.strip()

        # Extract fenced JSON first, else first {...} blob
        match = re.search(r"```(?:json)?\s*({.*?})\s*```", raw_stripped, re.DOTALL)
        if match:
            raw_stripped = match.group(1)
        else:
            json_match = re.search(r"({.*})", raw_stripped, re.DOTALL)
            if not json_match:
                raise ValueError(f"LLM output did not contain JSON:\n{raw}")
            raw_stripped = json_match.group(1)

        try:
            result = json.loads(raw_stripped)
        except json.JSONDecodeError as e:
            raise ValueError(f"LLM returned invalid JSON after cleaning:\n{raw_stripped}") from e

    # Normalize fields
    script = str(result.get("script", "") or "").strip()
    beats  = _sanitize_beats(result.get("beats", []))
    hooks  = _sanitize_hooks(result.get("hooks", []))

    # Fallback hook if LLM didn't supply them
    if not hooks:
        # first non-empty line of script
        first = ""
        for ln in script.splitlines():
            s = ln.strip()
            if s:
                first = s
                break
        hooks = _sanitize_hooks([first]) if first else []

    if not script:
        raise ValueError("LLM returned empty 'script'")
    return {"script": script, "beats": beats, "hooks": hooks}

# ───────────────────  Convenience wrapper  ──────────────────────────────────
def generate_video_assets(transcript: str,
                          title: str,
                          workdir: Path,
                          *,
                          overwrite: bool = True,
                          model: str = DEFAULT_MODEL
                          ) -> Dict[str, Any]:
    """
    High-level helper used by your runner
    • Calls the LLM
    • Writes <workdir>/script.txt, <workdir>/beats.json, <workdir>/hooks.json
    • Returns the same dict
    """
    workdir.mkdir(parents=True, exist_ok=True)

    result = generate_video_script(transcript, title, model=model)

    script_path = workdir / "script.txt"
    beats_path  = workdir / "beats.json"
    hooks_path  = workdir / "hooks.json"

    if not overwrite and any(p.exists() for p in (script_path, beats_path, hooks_path)):
        raise FileExistsError("One or more of script.txt / beats.json / hooks.json already exist")

    # Writes
    script_path.write_text(result["script"], encoding="utf-8")
    beats_path.write_text(json.dumps(result["beats"], indent=2), encoding="utf-8")
    hooks_path.write_text(json.dumps({"hooks": result["hooks"]}, indent=2), encoding="utf-8")

    print(f"📝  Saved script.txt → {script_path}")
    print(f"🗂️  Saved beats.json →  {beats_path}")
    print(f"🎯  Saved hooks.json →  {hooks_path}")

    return result