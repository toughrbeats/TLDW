"""
yt_trending.py
──────────────
Lightweight helper for finding long-form, fast-rising YouTube
videos (“semi-viral”) in any region.

Dependencies
------------
pip install google-api-python-client python-dotenv tabulate yt-dlp whisper
"""

from __future__ import annotations
import os
import re
import sys
import json
import time
import math
import tempfile
import datetime as dt
import subprocess
from typing import List, Dict, Tuple

from googleapiclient.discovery import build
from dotenv import load_dotenv
from tabulate import tabulate
from youtube_transcript_api import YouTubeTranscriptApi, TranscriptsDisabled, NoTranscriptFound

# ── ENV ───────────────────────────────────────────────────────────────
load_dotenv()
API_KEY     = os.getenv("YOUTUBE_API_KEY")
REGION_CODE = os.getenv("REGION_CODE", "US")

if not API_KEY:
    raise EnvironmentError("Missing YOUTUBE_API_KEY in environment (.env)")

YT = build("youtube", "v3", developerKey=API_KEY)

# ── BASIC HELPERS ─────────────────────────────────────────────────────
_ISO_RE = re.compile(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?")

def iso_to_seconds(iso: str) -> int:
    """
    Convert an ISO-8601 duration string (e.g. 'PT1H22M13S') to seconds.
    """
    h, m, s = 0, 0, 0
    mobj = _ISO_RE.match(iso)
    if mobj:
        h, m, s = [int(x) if x else 0 for x in mobj.groups()]
    return h * 3600 + m * 60 + s

def views_per_hour(item: dict) -> float:
    """
    Compute raw VPH for a video item dict from videos().list().
    """
    views = int(item["statistics"].get("viewCount", 0))
    published = dt.datetime.strptime(
        item["snippet"]["publishedAt"], "%Y-%m-%dT%H:%M:%SZ"
    )
    hrs = (dt.datetime.utcnow() - published).total_seconds() / 3600
    return views / hrs if hrs else 0.0

# ── TRENDING CALL ─────────────────────────────────────────────────────
def get_trending(region: str, quota_left: List[int] = [9000]) -> List[dict]:
    """
    Return the first (max 50) “Most Popular” videos for a region.
    YouTube API cost: 100 units.
    """
    res = (
        YT.videos()
        .list(
            part="id,snippet,statistics,contentDetails",
            chart="mostPopular",
            maxResults=50,
            regionCode=region,
        )
        .execute()
    )
    quota_left[0] -= 100
    return res["items"]

# ── TRANSCRIPT HELPERS (optional) ─────────────────────────────────────
def fetch_youtube_captions(video_id: str, lang: str = "en") -> str | None:
    try:
        srt = YouTubeTranscriptApi.get_transcript(
            video_id, languages=[lang, "en-US", "en"]
        )
        return "\n".join(
            f"{round(seg['start'],2)} --> {round(seg['start']+seg['duration'],2)}\n"
            f"{seg['text']}"
            for seg in srt
        )
    except (TranscriptsDisabled, NoTranscriptFound):
        return None

def whisper_transcribe(video_id: str, model: str = "base") -> str:
    """
    Download audio with yt-dlp → run Whisper → return plain text.
    """
    with tempfile.TemporaryDirectory() as tmp:
        mp3 = os.path.join(tmp, f"{video_id}.mp3")
        subprocess.run(
            [
                "yt-dlp",
                "-f",
                "bestaudio",
                "--extract-audio",
                "--audio-format",
                "mp3",
                "-o",
                mp3,
                f"https://youtu.be/{video_id}",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        import whisper

        model = whisper.load_model(model)
        result = model.transcribe(mp3)
        return result["text"]

def get_transcript(video_id: str) -> Tuple[str, str]:
    """
    caption → whisper fallback.  Returns (transcript_text, source_tag).
    """
    cap = fetch_youtube_captions(video_id)
    if cap:
        return cap, "captions"
    return whisper_transcribe(video_id), "whisper"

# ── MAIN DISCOVERY ROUTINE ────────────────────────────────────────────
def discover_longform_semiviral(
    region: str = REGION_CODE,
    min_minutes: int = 15,
    vph_low: int = 2_000,
    vph_high: int = 40_000,
) -> List[Dict]:
    """
    Return a sorted list of candidate dicts with keys:
      id, title, length, views/h, total, url
    """
    candidates: List[Dict] = []

    for vid in get_trending(region):
        dur_sec = iso_to_seconds(vid["contentDetails"]["duration"])
        if dur_sec < min_minutes * 60:  # skip short videos
            continue

        vph = views_per_hour(vid)
        if vph_low <= vph <= vph_high:
            candidates.append(
                {
                    "id": vid["id"],
                    "title": vid["snippet"]["title"],
                    "length": f"{dur_sec // 60} min",
                    "views/h": vph,
                    "total": int(vid["statistics"]["viewCount"]),
                    "url": f"https://youtu.be/{vid['id']}",
                }
            )

    # rank by VPH descending
    return sorted(candidates, key=lambda x: x["views/h"], reverse=True)

# ── CLI ENTRYPOINT ----------------------------------------------------
def main(top_n: int = 3) -> None:
    """
    1) Pull semi-viral long-form hits
    2) Fetch transcripts for top N (optional)
    3) Pretty-print a table
    """
    hits = discover_longform_semiviral()

    # --- optional transcript fetch -----------------------------------
    for clip in hits[:top_n]:
        print(f"\n▶ Fetching transcript for: {clip['title'][:60]}")
        txt, src = get_transcript(clip["id"])
        fname = f"{clip['id']}_{src}.txt"
        with open(fname, "w", encoding="utf-8") as fh:
            fh.write(txt)
        print(f"   ✔ saved → {fname}")

    # --- table summary ----------------------------------------------
    if hits:
        pretty = [
            {
                "Title": h["title"][:60],
                "Len": h["length"],
                "VPH": f"{h['views/h']:,.0f}",
                "Total Views": f"{h['total']:,}",
                "URL": h["url"],
            }
            for h in hits
        ]
        print("\n=== SEMI-VIRAL LONG-FORM VIDEOS ===")
        print(tabulate(pretty, headers="keys"))
    else:
        print("No semi-viral long-form videos found.")

# ── RUN DIRECTLY ------------------------------------------------------
if __name__ == "__main__":
    main(top_n=3)
