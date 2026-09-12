"""Local-only Qwen3 VoiceDesign worker. Never plays audio or opens a socket.

The official Qwen wrapper currently drops extra generation kwargs before the
talker. inject_cancellation therefore wraps that *instance* for one serial call.
It does not edit qwen-tts, and always restores the bound method afterwards.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import ctypes
import json
import os
from pathlib import Path
import re
import threading
import time
import uuid

PROTOCOL = 1
MAX_TEXT = 10000
MAX_REQUEST_BYTES = 128 * 1024
PROFILE_ID = re.compile(r"[a-z][a-z0-9-]{0,63}\Z")


class Cancelled(RuntimeError):
    pass


class RequestTimeout(RuntimeError):
    pass


def is_uuid(value):
    return isinstance(value, str) and bool(re.fullmatch(
        r"[0-9a-f]{32}", value)) and uuid.UUID(hex=value).hex == value


def inside(workspace, value, *, must_exist=True):
    path = Path(value)
    if not path.is_absolute():
        path = workspace / path
    path = path.resolve(strict=must_exist)
    path.relative_to(workspace)
    return path


def atomic_json(path, value):
    temporary = path.with_name(path.name + ".partial")
    try:
        temporary.write_text(json.dumps(value, ensure_ascii=False), encoding="utf-8")
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def read_json(path, maximum=MAX_REQUEST_BYTES):
    # All paths originate in our directory, never in a request's payload.
    if path.is_symlink() or (hasattr(path, "is_junction") and path.is_junction()):
        raise ValueError("Linked file")
    if path.stat().st_size > maximum:
        raise ValueError("Oversized file")
    return json.loads(path.read_text(encoding="utf-8-sig"))


def load_profiles(workspace, filename):
    data = read_json(inside(workspace, filename))
    entries = data.get("profiles") if isinstance(data, dict) else None
    if not isinstance(entries, list) or not 1 <= len(entries) <= 4:
        raise ValueError("Invalid profiles")
    result = {}
    for item in entries:
        if not isinstance(item, dict) or set(item) != {"id", "instruct", "seed"}:
            raise ValueError("Invalid profile")
        key, instruct = item["id"], item["instruct"]
        if not isinstance(key, str) or not PROFILE_ID.fullmatch(key) or key in result:
            raise ValueError("Invalid profile id")
        if not isinstance(instruct, str) or not instruct.strip() or len(instruct) > 2000:
            raise ValueError("Invalid voice instruction")
        if type(item["seed"]) is not int or not 0 <= item["seed"] <= 0x7FFFFFFF:
            raise ValueError("Invalid seed")
        result[key] = {"instruct": instruct, "seed": item["seed"]}
    return result


def validate_request(value, request_id, profiles):
    if not isinstance(value, dict) or set(value) != {"id", "text", "voice", "rate", "client_pid"}:
        raise ValueError("Invalid request fields")
    if not is_uuid(value["id"]) or value["id"] != request_id:
        raise ValueError("Invalid request id")
    text = value["text"]
    if not isinstance(text, str) or not text.strip() or len(text) > MAX_TEXT or "\x00" in text:
        raise ValueError("Invalid text")
    if not isinstance(value["voice"], str) or value["voice"] not in profiles:
        raise ValueError("Invalid voice")
    if type(value["rate"]) is not int or not -30 <= value["rate"] <= 50:
        raise ValueError("Invalid rate")
    if type(value["client_pid"]) is not int or not 1 <= value["client_pid"] <= 0xFFFFFFFF:
        raise ValueError("Invalid client")
    return value


def split_text(text, maximum=220):
    """Keep every character, prefer sentence boundaries, never truncate text."""
    if maximum < 1:
        raise ValueError("Invalid chunk size")
    parts = []
    while text:
        end = min(maximum, len(text))
        if len(text) > maximum:
            candidates = [m.end() for m in re.finditer(r"[。！？!?；;\n]", text[:maximum])]
            if candidates:
                end = candidates[-1]
            else:
                candidates = [m.end() for m in re.finditer(r"[，,、\s]", text[:maximum])]
                if candidates and candidates[-1] >= maximum // 2:
                    end = candidates[-1]
        parts.append(text[:end])
        text = text[end:]
    return parts


class ProcessWatch:
    """Hold a Windows process handle, so a recycled PID is never 'still alive'."""
    def __init__(self, pid):
        self.handle = None
        self.pid = pid
        if os.name == "nt":
            self.api = ctypes.WinDLL("kernel32", use_last_error=True)
            self.api.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
            self.api.OpenProcess.restype = ctypes.c_void_p
            self.api.WaitForSingleObject.argtypes = [ctypes.c_void_p, ctypes.c_uint32]
            self.api.WaitForSingleObject.restype = ctypes.c_uint32
            self.api.CloseHandle.argtypes = [ctypes.c_void_p]
            self.api.CloseHandle.restype = ctypes.c_int
            self.handle = self.api.OpenProcess(0x00100000, False, pid)  # SYNCHRONIZE

    def alive(self):
        if os.name == "nt":
            return bool(self.handle) and self.api.WaitForSingleObject(self.handle, 0) == 0x102
        try:
            os.kill(self.pid, 0)
            return True
        except OSError:
            return False

    def close(self):
        if self.handle is not None:
            self.api.CloseHandle(self.handle)
            self.handle = None


@contextmanager
def inject_cancellation(talker, check, stopping_type, stopping_list_type):
    """Inject at HF GenerationMixin's actual entry, not Qwen's dropped kwargs."""
    original = talker.generate
    had_override = "generate" in vars(talker)
    previous_override = vars(talker).get("generate")

    class AliveCriteria(stopping_type):
        def __call__(self, input_ids, scores, **kwargs):
            # Unwind immediately rather than returning partial codes to decode.
            check()
            return False

    def cancellable_generate(*args, **kwargs):
        check()
        criteria = list(kwargs.pop("stopping_criteria", []) or [])
        kwargs["stopping_criteria"] = stopping_list_type(criteria + [AliveCriteria()])
        return original(*args, **kwargs)

    talker.generate = cancellable_generate
    try:
        yield
    finally:
        if had_override:
            talker.generate = previous_override
        else:
            delattr(talker, "generate")


class QwenEngine:
    def __init__(self, model_path, profiles):
        # Do not let any loader download missing assets in the live assistant.
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        import torch
        from qwen_tts import Qwen3TTSModel
        from transformers import StoppingCriteria, StoppingCriteriaList
        if not torch.cuda.is_available():
            raise RuntimeError("CUDA required")
        self.stop_type, self.stop_list = StoppingCriteria, StoppingCriteriaList
        torch.set_num_threads(4)
        torch.set_num_interop_threads(2)
        self.model = Qwen3TTSModel.from_pretrained(
            str(model_path), device_map="cuda:0", dtype=torch.bfloat16,
            attn_implementation="sdpa", local_files_only=True)
        if self.model.model.tts_model_type != "voice_design":
            raise ValueError("VoiceDesign model required")
        self.profiles = profiles

    def synthesize_to_file(self, text, voice, rate, destination, check):
        import librosa
        import numpy as np
        import soundfile as sf
        import torch
        profile = self.profiles[voice]
        chunks, sample_rate = [], None
        with inject_cancellation(self.model.model.talker, check, self.stop_type, self.stop_list):
            for part in split_text(text):
                check()
                if not part.strip():
                    continue
                # A fixed original design preset, not a reference-person clone.
                # Fixed seed aids repeatability; it does not guarantee identical
                # timbre across different texts as reference cloning would.
                torch.manual_seed(profile["seed"])
                torch.cuda.manual_seed_all(profile["seed"])
                wavs, sr = self.model.generate_voice_design(
                    text=part, language="Chinese", instruct=profile["instruct"], max_new_tokens=2048)
                check()
                if not wavs or not len(wavs[0]) or (sample_rate is not None and sr != sample_rate):
                    raise RuntimeError("Invalid model audio")
                audio = np.asarray(wavs[0], dtype=np.float32)
                if audio.ndim != 1 or not np.isfinite(audio).all():
                    raise RuntimeError("Invalid model audio")
                sample_rate = int(sr)
                if rate:
                    audio = librosa.effects.time_stretch(audio, rate=1.0 + rate / 100.0)
                check()
                chunks.append(audio)
        check()
        if not chunks:
            raise RuntimeError("Empty model audio")
        sf.write(str(destination), np.concatenate(chunks), sample_rate, format="WAV", subtype="PCM_16")
        check()
        return sample_rate

    def close(self):
        self.profiles = {}
        self.model = None
        import gc
        import torch
        gc.collect()
        torch.cuda.empty_cache()


class MailboxServer:
    def __init__(self, state_dir, profiles, parent, engine, *, process_factory=ProcessWatch, timeout=600):
        self.state_dir, self.profiles, self.parent, self.engine = state_dir, profiles, parent, engine
        self.process_factory, self.timeout = process_factory, timeout
        self.seen = set()
        self.delivered = {}

    def status(self, state, error=None):
        value = {"protocol": PROTOCOL, "state": state, "pid": os.getpid()}
        if error:
            value["error"] = error
        atomic_json(self.state_dir / "status.json", value)
        if state in {"ready", "error"}:
            atomic_json(self.state_dir / "ready.json", dict(value, voices=sorted(self.profiles)))

    def clean_result(self, request_id):
        for suffix in (".wav", ".json", ".partial.wav", ".json.partial"):
            (self.state_dir / ("result-" + request_id + suffix)).unlink(missing_ok=True)

    def reap(self):
        for request_id, watch in list(self.delivered.items()):
            if not watch.alive() or not (self.state_dir / ("result-" + request_id + ".json")).exists():
                self.clean_result(request_id)
                watch.close()
                del self.delivered[request_id]

    def process_request(self, path):
        request_id = path.name.removeprefix("request-").removesuffix(".json")
        if not is_uuid(request_id):
            path.unlink(missing_ok=True)
            return
        if request_id in self.seen:
            path.unlink(missing_ok=True)
            return
        self.seen.add(request_id)
        watch = None
        claimed = self.state_dir / ("processing-" + request_id + ".json")
        partial = self.state_dir / ("result-" + request_id + ".partial.wav")
        wav = self.state_dir / ("result-" + request_id + ".wav")
        result = self.state_dir / ("result-" + request_id + ".json")
        started = time.monotonic()
        try:
            os.replace(path, claimed)
            try:
                request = validate_request(read_json(claimed), request_id, self.profiles)
            finally:
                claimed.unlink(missing_ok=True)
            watch = self.process_factory(request["client_pid"])

            def check():
                if not self.parent.alive() or not watch.alive():
                    raise Cancelled()
                if time.monotonic() - started > self.timeout:
                    raise RequestTimeout()

            check()
            self.status("generating")
            sr = self.engine.synthesize_to_file(request["text"], request["voice"], request["rate"], partial, check)
            check()
            if not partial.is_file() or partial.stat().st_size <= 44:
                raise RuntimeError("Empty wave")
            os.replace(partial, wav)
            check()
            atomic_json(result, {"id": request_id, "ok": True, "sample_rate": sr})
            check()
            self.delivered[request_id], watch = watch, None
        except Cancelled:
            self.clean_result(request_id)
        except Exception as exc:
            self.clean_result(request_id)
            if self.parent.alive() and (watch is None or watch.alive()):
                atomic_json(result, {"id": request_id, "ok": False, "error": type(exc).__name__})
                if watch is not None:
                    self.delivered[request_id], watch = watch, None
        finally:
            claimed.unlink(missing_ok=True)
            partial.unlink(missing_ok=True)
            if watch is not None:
                watch.close()
            if self.parent.alive():
                self.status("ready")

    def run(self):
        self.status("ready")
        atomic_json(self.state_dir / "ready.json", {
            "protocol": PROTOCOL, "state": "ready", "pid": os.getpid(), "voices": sorted(self.profiles)})
        while self.parent.alive():
            self.reap()
            for path in sorted(self.state_dir.glob("request-*.json"), key=lambda p: p.name):
                if not self.parent.alive():
                    break
                self.process_request(path)
            time.sleep(0.05)

    def close(self, *, preserve_status=False):
        if not preserve_status:
            (self.state_dir / "ready.json").unlink(missing_ok=True)
        for request_id, watch in self.delivered.items():
            self.clean_result(request_id)
            watch.close()
        self.delivered.clear()
        # This is a per-run mailbox. Never leave unprocessed answer text behind.
        for prefix in ("request-", "processing-", "result-"):
            for path in self.state_dir.glob(prefix + "*"):
                candidate = path.name[len(prefix):].split(".", 1)[0]
                if is_uuid(candidate) and path.is_file():
                    path.unlink(missing_ok=True)
        if not preserve_status:
            self.status("stopped")
        self.engine.close()


def main():
    parser = argparse.ArgumentParser()
    for name in ("workspace", "state-dir", "model-path", "profiles-path"):
        parser.add_argument("--" + name, required=True)
    parser.add_argument("--parent-pid", required=True, type=int)
    args = parser.parse_args()
    workspace = Path(args.workspace).resolve(strict=True)
    state = inside(workspace, args.state_dir, must_exist=False)
    state.mkdir(parents=True, exist_ok=True)
    ready = state / "ready.json"
    ready.unlink(missing_ok=True)
    parent = ProcessWatch(args.parent_pid)
    finished = threading.Event()

    def parent_guard():
        while not finished.wait(0.2):
            if not parent.alive():
                try:
                    ready.unlink(missing_ok=True)
                except OSError:
                    pass
                # Normal generation checks unwind cooperatively; also cover a
                # parent closing while model loading or a CUDA kernel hangs.
                if not finished.wait(3.0):
                    os._exit(0)
                return

    guard = threading.Thread(target=parent_guard, daemon=True)
    guard.start()
    engine = server = None
    failed = False
    try:
        if not parent.alive():
            return
        starting = {"protocol": PROTOCOL, "state": "starting", "pid": os.getpid(), "voices": []}
        atomic_json(ready, starting)
        atomic_json(state / "status.json", starting)
        model_path = inside(workspace, args.model_path)
        if not model_path.is_dir():
            raise ValueError("Invalid model")
        profiles = load_profiles(workspace, args.profiles_path)
        engine = QwenEngine(model_path, profiles)
        if not parent.alive():
            return
        server = MailboxServer(state, profiles, parent, engine)
        server.run()
    except Exception as exc:
        failed = True
        failure = {"protocol": PROTOCOL, "state": "error", "pid": os.getpid(), "voices": [], "error": type(exc).__name__}
        atomic_json(ready, failure)
        atomic_json(state / "status.json", failure)
        return 1
    finally:
        if not failed:
            ready.unlink(missing_ok=True)
        if server is not None:
            server.close(preserve_status=failed)
        elif engine is not None:
            engine.close()
        finished.set()
        parent.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
