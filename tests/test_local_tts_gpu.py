"""Opt-in real VoiceDesign mailbox validation; generated WAVs are never played.

Run only after the sample-generation worker has exited and released the GPU.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "src"))
from local_tts_server import atomic_json
from local_tts_client import synthesize_local


def read_json(path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}


def wait_until(predicate, timeout, process=None):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        if process and process.poll() is not None:
            raise AssertionError("ServerExited")
        time.sleep(0.05)
    raise AssertionError("WaitTimeout")


def run():
    parser = argparse.ArgumentParser()
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    if not args.execute:
        print("Skipped: pass --execute after the sample worker releases the GPU. No audio playback.")
        return
    base = ROOT / "work" / "tests" / "local-tts-gpu"
    base.mkdir(parents=True, exist_ok=True)
    state = base / uuid.uuid4().hex / "local-voice"
    state.mkdir(parents=True)
    python = ROOT / "runtime" / "voice-design" / "venv" / "Scripts" / "python.exe"
    model = ROOT / "runtime" / "voice-design" / "models" / "Qwen3-TTS-12Hz-1.7B-VoiceDesign"
    profiles = ROOT / "assets" / "local-voices" / "profiles.json"
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)
    parent = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(600)"], creationflags=flags)
    server = client = None
    evidence = {"passed": False, "microphone": False, "playback": False, "stateDir": str(state), "checks": {}}
    log = (base / "worker.log").open("w", encoding="utf-8")
    try:
        began = time.monotonic()
        server = subprocess.Popen([str(python), "-B", str(ROOT / "src" / "local_tts_server.py"),
            "--workspace", str(ROOT), "--state-dir", str(state), "--parent-pid", str(parent.pid),
            "--model-path", str(model), "--profiles-path", str(profiles)], creationflags=flags,
            stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        def ready():
            value = read_json(state / "ready.json")
            if value.get("state") == "error":
                raise AssertionError("Startup_" + value.get("error", "Error"))
            return value if value.get("state") == "ready" else None
        value = wait_until(ready, 180, server)
        evidence["loadSeconds"] = round(time.monotonic() - began, 3)
        expected_voices = sorted(item["id"] for item in read_json(profiles)["profiles"])
        assert value["pid"] == server.pid and sorted(value["voices"]) == expected_voices
        evidence["voices"] = expected_voices
        evidence["checks"]["configured_presets_ready"] = True
        print("GPU worker ready; testing real generation, cancellation, and recovery.", flush=True)

        def submit(text, rate, client_pid):
            key = uuid.uuid4().hex
            atomic_json(state / ("request-" + key + ".json"), {
                "id": key, "text": text, "voice": "local-tw-sweet", "rate": rate, "client_pid": client_pid})
            return key

        def render_with_client(rate, label):
            audio = base / (label + ".wav")
            began = time.monotonic()
            synthesize_local({"text": "准备好了。", "voice": "local-tw-sweet", "rate": rate,
                              "local_state_dir": str(state)}, audio, ROOT, timeout=180)
            with wave.open(str(audio)) as reader:
                info = {"frames": reader.getnframes(), "rate": reader.getframerate(), "channels": reader.getnchannels()}
            info["elapsedSeconds"] = round(time.monotonic() - began, 3)
            assert info["frames"] > 0 and info["channels"] == 1
            return info

        normal = render_with_client(0, "normal")
        evidence["normalWave"] = normal
        evidence["checks"]["real_pcm_wave"] = True
        evidence["checks"]["production_client_connected"] = True
        client = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(180)"], creationflags=flags)
        cancelled = submit("这是一段用于取消验证的自拟内容。" * 10, 0, client.pid)
        wait_until(lambda: read_json(state / "status.json").get("state") == "generating", 10, server)
        time.sleep(1.0)
        cancel_began = time.monotonic()
        client.terminate()
        client.wait(timeout=5)
        wait_until(lambda: read_json(state / "status.json").get("state") == "ready", 15, server)
        evidence["cancelSeconds"] = round(time.monotonic() - cancel_began, 3)
        assert not list(state.glob("result-" + cancelled + "*"))
        evidence["checks"]["cancelled_request_has_no_late_result"] = True
        faster = render_with_client(20, "faster")
        evidence["fasterWave"] = faster
        ratio = (faster["frames"] / faster["rate"]) / (normal["frames"] / normal["rate"])
        assert 0.79 <= ratio <= 0.87, ratio
        evidence["checks"]["same_model_recovers_after_cancel"] = True
        evidence["checks"]["rate_20_shortens_audio"] = True
        exit_began = time.monotonic()
        parent.terminate()
        parent.wait(timeout=5)
        server.wait(timeout=8)
        evidence["parentExitSeconds"] = round(time.monotonic() - exit_began, 3)
        assert not (state / "ready.json").exists()
        evidence["checks"]["parent_exit_releases_worker"] = True
        evidence["passed"] = True
    except Exception as exc:
        evidence["error"] = type(exc).__name__
        raise
    finally:
        for process in (client, server, parent):
            if process and process.poll() is None:
                process.kill()
                process.wait(timeout=8)
        log.close()
        (base / "result.json").write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(evidence, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    run()
