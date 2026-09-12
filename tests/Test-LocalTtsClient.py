"""Owned temporary mailbox and fake worker; no models, network or audio output."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import wave

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from local_tts_client import LocalSpeechError, _atomic_json, synthesize_local


class LocalClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.state = self.root / "work" / "fixture" / "local-voice"
        self.state.mkdir(parents=True)
        self.output = self.root / "answer.wav"
        self.job = {"local_state_dir": str(self.state), "voice": "local-tw-sweet",
                    "text": "A private example sentence.", "rate": 20}
        self.threads = []

    def tearDown(self):
        for thread in self.threads:
            thread.join(timeout=3)
        self.temp.cleanup()

    def ready(self, pid=None, voices=None):
        _atomic_json(self.state / "ready.json", {"state": "ready", "pid": pid or os.getpid(),
                                               "voices": voices if voices is not None else [self.job["voice"]]})

    def responder(self, mode="success", delay_ready=0):
        self.seen = None
        def worker():
            if delay_ready:
                time.sleep(delay_ready)
                self.ready()
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                requests = list(self.state.glob("request-*.json"))
                if requests:
                    request = requests[0]
                    payload = json.loads(request.read_text(encoding="utf-8"))
                    self.seen = payload
                    request.unlink()
                    audio = self.state / f"result-{payload['id']}.wav"
                    if mode == "success":
                        with wave.open(str(audio), "wb") as clip:
                            clip.setnchannels(1); clip.setsampwidth(2); clip.setframerate(24000)
                            clip.writeframes(b"\0\0" * 2400)
                    elif mode == "bad_audio":
                        audio.write_bytes(b"not a WAV")
                    _atomic_json(self.state / f"result-{payload['id']}.json",
                                 {"id": payload["id"], "ok": mode != "error", "sample_rate": 24000})
                    return
                time.sleep(.01)
        thread = threading.Thread(target=worker, daemon=True)
        self.threads.append(thread); thread.start()

    def assert_clean(self):
        self.assertFalse(list(self.state.glob("request-*")))
        self.assertFalse(list(self.state.glob("result-*")))
        self.assertFalse(self.output.with_suffix(".partial.wav").exists())

    def test_wait_for_model_then_publish_complete_wav(self):
        _atomic_json(self.state / "ready.json", {"state": "starting", "pid": os.getpid()})
        self.responder(delay_ready=.15)
        synthesize_local(self.job, self.output, self.root, timeout=3)
        with wave.open(str(self.output), "rb") as clip:
            self.assertEqual(clip.getnframes(), 2400)
        self.assertEqual(self.seen["text"], self.job["text"])
        self.assertEqual(self.seen["rate"], 20)
        self.assertEqual(self.seen["client_pid"], os.getpid())
        self.assertEqual(set(self.seen), {"id", "text", "voice", "rate", "client_pid"})
        self.assert_clean()

    def test_server_error_does_not_replace_output(self):
        self.output.write_bytes(b"previous output")
        self.ready(); self.responder("error")
        with self.assertRaisesRegex(LocalSpeechError, "SynthesisFailed"):
            synthesize_local(self.job, self.output, self.root, timeout=3)
        self.assertEqual(self.output.read_bytes(), b"previous output")
        self.assert_clean()

    def test_corrupt_audio_is_never_published(self):
        self.ready(); self.responder("bad_audio")
        with self.assertRaises((LocalSpeechError, wave.Error, EOFError)):
            synthesize_local(self.job, self.output, self.root, timeout=3)
        self.assertFalse(self.output.exists()); self.assert_clean()

    def test_unknown_voice_is_rejected_without_submission(self):
        self.ready(voices=["local-tw-natural"])
        with self.assertRaisesRegex(LocalSpeechError, "VoiceUnavailable"):
            synthesize_local(self.job, self.output, self.root, timeout=1)
        self.assert_clean()

    def test_startup_error_is_fast_and_sanitized(self):
        _atomic_json(self.state / "ready.json", {"state": "error", "error": self.job["text"]})
        with self.assertRaisesRegex(LocalSpeechError, "^ServiceUnavailable$"):
            synthesize_local(self.job, self.output, self.root, timeout=1)
        self.assert_clean()

    def test_loading_timeout_leaves_no_files(self):
        _atomic_json(self.state / "ready.json", {"state": "starting", "pid": os.getpid()})
        with self.assertRaisesRegex(LocalSpeechError, "SynthesisTimeout"):
            synthesize_local(self.job, self.output, self.root, timeout=.15)
        self.assert_clean()

    def test_dead_service_does_not_wait_for_ten_minute_deadline(self):
        child = subprocess.Popen([sys.executable, "-c", "pass"], creationflags=subprocess.CREATE_NO_WINDOW)
        child.wait(timeout=3)
        self.ready(pid=child.pid)
        started = time.monotonic()
        with self.assertRaisesRegex(LocalSpeechError, "ServiceExited"):
            synthesize_local(self.job, self.output, self.root, timeout=10)
        self.assertLess(time.monotonic() - started, 1)
        self.assert_clean()

    def test_service_exit_during_model_loading_fails_promptly(self):
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(.25)"],
                                 creationflags=subprocess.CREATE_NO_WINDOW)
        try:
            _atomic_json(self.state / "ready.json", {"state": "starting", "pid": child.pid})
            started = time.monotonic()
            with self.assertRaisesRegex(LocalSpeechError, "ServiceExited"):
                synthesize_local(self.job, self.output, self.root, timeout=10)
            self.assertLess(time.monotonic() - started, 2)
            self.assert_clean()
        finally:
            child.wait(timeout=3)

    def test_state_directory_must_belong_to_app(self):
        outside = self.root / "elsewhere" / "local-voice"
        outside.mkdir(parents=True)
        self.job["local_state_dir"] = str(outside)
        with self.assertRaisesRegex(LocalSpeechError, "InvalidStateDirectory"):
            synthesize_local(self.job, self.output, self.root, timeout=1)

    def test_invalid_text_does_not_submit(self):
        self.job["text"] = "x" * 10001
        with self.assertRaisesRegex(LocalSpeechError, "InvalidText"):
            synthesize_local(self.job, self.output, self.root, timeout=1)
        self.assert_clean()


if __name__ == "__main__":
    unittest.main(verbosity=2)
