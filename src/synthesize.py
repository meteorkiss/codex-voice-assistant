"""Generate one clip using the user's approved Microsoft online Taiwan voice."""
import asyncio
import json
import os
import sys
from pathlib import Path

import edge_tts


async def generate(job_path: Path, audio_path: Path) -> None:
    job = json.loads(job_path.read_text(encoding="utf-8-sig"))
    job_path.unlink(missing_ok=True)
    voices_path = Path(__file__).resolve().parent.parent / "assets" / "voices.json"
    voices = json.loads(voices_path.read_text(encoding="utf-8-sig"))
    if job["voice"] not in {voice["id"] for voice in voices}:
        raise ValueError("Unsupported voice")
    text = job["text"]
    if not isinstance(text, str) or not text.strip():
        raise ValueError("Empty answer")
    rate = max(-30, min(50, int(job.get("rate", 0))))
    temporary = audio_path.with_suffix(".partial.mp3")
    try:
        await edge_tts.Communicate(
            text, job["voice"], rate=f"{rate:+d}%",
            connect_timeout=15, receive_timeout=30,
        ).save(str(temporary))
        if temporary.stat().st_size < 256:
            raise RuntimeError("Empty audio")
        os.replace(temporary, audio_path)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    job_path, audio_path = map(Path, sys.argv[1:3])
    try:
        asyncio.run(generate(job_path, audio_path))
    except Exception as exc:
        # Keep diagnostics free of answer text, request URLs, and credentials.
        audio_path.with_suffix(".error.json").write_text(
            json.dumps({"error": type(exc).__name__}), encoding="utf-8"
        )
        job_path.unlink(missing_ok=True)
        sys.exit(1)
