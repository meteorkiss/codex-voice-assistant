"""Submit one local speech job to the owned, persistent GPU worker.

This module never opens a network connection or an audio device. The normal
synthesis subprocess remains the lifetime/cancellation boundary for each job.
"""
from __future__ import annotations

import json
import ctypes
from ctypes import wintypes
import os
import shutil
import time
import uuid
import wave
from pathlib import Path


class LocalSpeechError(RuntimeError):
    pass


class _ServiceProcess:
    """Hold a handle to the announced worker so PID reuse cannot hide its exit."""
    def __init__(self, process_id: int):
        if not isinstance(process_id, int) or isinstance(process_id, bool) or process_id <= 0:
            raise LocalSpeechError("InvalidServiceProcess")
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.WaitForSingleObject.restype = wintypes.DWORD
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL
        self.handle = self.kernel.OpenProcess(0x00100000, False, process_id)
        if not self.handle:
            raise LocalSpeechError("ServiceExited")

    def alive(self) -> bool:
        return bool(self.handle and self.kernel.WaitForSingleObject(self.handle, 0) == 258)

    def close(self) -> None:
        if self.handle:
            self.kernel.CloseHandle(self.handle)
            self.handle = None


def _read_json(path: Path) -> dict | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return value if isinstance(value, dict) else None


def _owned_state(path: str | Path, workspace: Path) -> Path:
    candidate = Path(path).resolve(strict=True)
    if not candidate.is_dir() or candidate.name != "local-voice":
        raise LocalSpeechError("InvalidStateDirectory")
    root = workspace.resolve(strict=True)
    if not any(candidate.is_relative_to(root / directory) for directory in ("data", "work")):
        raise LocalSpeechError("InvalidStateDirectory")
    return candidate


def _atomic_json(path: Path, value: dict) -> None:
    temporary = path.with_suffix(".tmp")
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def synthesize_local(job: dict, output: Path, workspace: Path, timeout: float = 600) -> None:
    state = _owned_state(job.get("local_state_dir", ""), workspace)
    text = job.get("text")
    voice = job.get("voice")
    if not isinstance(text, str) or not text.strip() or len(text) > 10000:
        raise LocalSpeechError("InvalidText")
    if not isinstance(voice, str) or not voice.startswith("local-tw-"):
        raise LocalSpeechError("InvalidVoice")
    rate = max(-30, min(50, int(job.get("rate", 0))))
    request_id = uuid.uuid4().hex
    request = state / f"request-{request_id}.json"
    result = state / f"result-{request_id}.json"
    audio = state / f"result-{request_id}.wav"
    partial = output.with_suffix(".partial.wav")
    deadline = time.monotonic() + timeout
    submitted = False
    process = None
    try:
        while time.monotonic() < deadline:
            ready = _read_json(state / "ready.json")
            if ready and ready.get("state") == "error":
                raise LocalSpeechError("ServiceUnavailable")
            if ready and ready.get("state") in ("starting", "ready") and not process:
                process = _ServiceProcess(ready.get("pid"))
            if process and not process.alive():
                raise LocalSpeechError("ServiceExited")
            if ready and ready.get("state") == "ready" and not submitted:
                if voice not in ready.get("voices", []):
                    raise LocalSpeechError("VoiceUnavailable")
                _atomic_json(request, {"id": request_id, "text": text, "voice": voice,
                                       "rate": rate, "client_pid": os.getpid()})
                submitted = True
            completed = _read_json(result) if submitted else None
            if completed:
                if completed.get("id") != request_id or completed.get("ok") is not True:
                    raise LocalSpeechError("SynthesisFailed")
                if not audio.is_file() or audio.stat().st_size > 100_000_000:
                    raise LocalSpeechError("InvalidAudio")
                with wave.open(str(audio), "rb") as clip:
                    if clip.getnframes() <= 0 or clip.getnchannels() not in (1, 2) or clip.getsampwidth() != 2:
                        raise LocalSpeechError("InvalidAudio")
                    if not 8000 <= clip.getframerate() <= 96000:
                        raise LocalSpeechError("InvalidAudio")
                shutil.copyfile(audio, partial)
                os.replace(partial, output)
                return
            time.sleep(0.1)
        raise LocalSpeechError("SynthesisTimeout")
    finally:
        if process:
            process.close()
        # The GPU service also observes this process's exit. A force-killed
        # client cannot run finally, so the service owns that cleanup case.
        for path in (request, result, audio, partial):
            path.unlink(missing_ok=True)
