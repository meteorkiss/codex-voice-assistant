"""Local mailbox/cancellation tests: fake model, no GPU/mic/speaker/network."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid
import wave

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "src"))
import local_tts_server as local

RUN = ROOT / "work" / "tests" / "local-tts-server"
RUN.mkdir(parents=True, exist_ok=True)


class Watch:
    def __init__(self, alive=True):
        self.live, self.closed = alive, False

    def alive(self):
        return self.live

    def close(self):
        self.closed = True


class Engine:
    def __init__(self, callback=None):
        self.calls, self.callback = [], callback

    def synthesize_to_file(self, text, voice, rate, destination, check):
        self.calls.append((text, voice, rate))
        check()
        if self.callback:
            self.callback(check)
        with wave.open(str(destination), "wb") as writer:
            writer.setparams((1, 2, 24000, 0, "NONE", "not compressed"))
            writer.writeframes(b"\x00\x00" * 240)
        return 24000

    def close(self):
        pass


class MailboxTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=RUN)
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)
        self.parent, self.client = Watch(), Watch()
        self.engine = Engine()
        self.server = local.MailboxServer(self.path, {"local-tw-sweet": {}}, self.parent,
                                          self.engine, process_factory=lambda pid: self.client)
        self.request_id = uuid.uuid4().hex

    def request(self, **changes):
        value = {"id": self.request_id, "text": "这是完整答案。第二句也要保留。", "voice": "local-tw-sweet",
                 "rate": 0, "client_pid": os.getpid()}
        value.update(changes)
        path = self.path / ("request-" + self.request_id + ".json")
        local.atomic_json(path, value)
        return path

    def result(self):
        return self.path / ("result-" + self.request_id + ".json")

    def test_success_atomic_ready_protocol_and_text_removed(self):
        self.server.process_request(self.request())
        value = local.read_json(self.result())
        self.assertEqual(value, {"id": self.request_id, "ok": True, "sample_rate": 24000})
        wav = self.path / ("result-" + self.request_id + ".wav")
        with wave.open(str(wav)) as reader:
            self.assertEqual(reader.getnframes(), 240)
        self.assertFalse(list(self.path.glob("request*")))
        self.assertFalse(list(self.path.glob("processing*")))
        self.assertFalse(list(self.path.glob("*.partial*")))
        self.assertEqual(self.engine.calls[0][0], "这是完整答案。第二句也要保留。")
        self.assertNotIn("完整答案", (self.path / "status.json").read_text(encoding="utf-8"))

    def test_duplicate_id_never_generates_twice(self):
        self.server.process_request(self.request())
        self.server.process_request(self.request())
        self.assertEqual(len(self.engine.calls), 1)

    def test_client_already_gone_does_not_generate(self):
        self.client.live = False
        self.server.process_request(self.request())
        self.assertFalse(self.result().exists())
        self.assertFalse(self.engine.calls)
        self.assertTrue(self.client.closed)

    def test_client_dies_during_generation_discards_partial_and_result(self):
        self.engine.callback = lambda check: setattr(self.client, "live", False)
        self.server.process_request(self.request())
        self.assertFalse(list(self.path.glob("result-*")))
        self.assertTrue(self.client.closed)

    def test_parent_dies_during_generation_discards_result(self):
        self.engine.callback = lambda check: setattr(self.parent, "live", False)
        self.server.process_request(self.request())
        self.assertFalse(list(self.path.glob("result-*")))

    def test_cancel_then_new_request_works_without_engine_reload(self):
        self.engine.callback = lambda check: setattr(self.client, "live", False)
        self.server.process_request(self.request())
        self.client, self.engine.callback = Watch(), None
        self.request_id = uuid.uuid4().hex
        self.server.process_request(self.request())
        self.assertTrue(local.read_json(self.result())["ok"])
        self.assertEqual(len(self.engine.calls), 2)

    def test_error_contains_type_only(self):
        def fail(check):
            raise ValueError("PRIVATE answer text and credentials")
        self.engine.callback = fail
        self.server.process_request(self.request())
        self.assertEqual(local.read_json(self.result())["error"], "ValueError")
        self.assertNotIn("PRIVATE", self.result().read_text())

    def test_timeout_is_typed_error_not_partial_audio(self):
        self.server.timeout = -1
        self.server.process_request(self.request())
        self.assertEqual(local.read_json(self.result())["error"], "RequestTimeout")
        self.assertFalse(list(self.path.glob("*.wav")))

    def test_reap_late_output_when_client_exits(self):
        self.server.process_request(self.request())
        self.client.live = False
        self.server.reap()
        self.assertFalse(list(self.path.glob("result-*")))
        self.assertTrue(self.client.closed)

    def test_reap_after_client_consumed_result_releases_watch(self):
        self.server.process_request(self.request())
        self.result().unlink()
        self.server.reap()
        self.assertTrue(self.client.closed)
        self.assertFalse(self.server.delivered)

    def test_malformed_filename_never_becomes_output_path(self):
        path = self.path / "request-not-a-uuid.json"
        path.write_text("{}")
        self.server.process_request(path)
        self.assertFalse(path.exists())
        self.assertFalse(self.engine.calls)
        self.assertFalse(list(self.path.glob("result-*")))

    def test_disallowed_payloads_never_reach_model(self):
        changes = [dict(id=uuid.uuid4().hex), dict(voice="../evil"), dict(voice="unknown"),
                   dict(rate=True), dict(rate=-31), dict(rate=51), dict(rate="20"),
                   dict(client_pid=True), dict(client_pid=0), dict(text=""), dict(text=" \n"),
                   dict(text="a" * 10001), dict(text="x\x00y"), dict(output_path="C:/evil.wav"),
                   dict(model_path="https://example.test/model")]
        for change in changes:
            with self.subTest(change=list(change)):
                self.request_id = uuid.uuid4().hex
                self.server.process_request(self.request(**change))
                self.assertFalse(self.engine.calls)
                self.assertEqual(local.read_json(self.result())["error"], "ValueError")

    def test_input_size_rejected_before_json_load(self):
        path = self.request()
        path.write_bytes(b"x" * (local.MAX_REQUEST_BYTES + 1))
        self.server.process_request(path)
        self.assertFalse(self.engine.calls)
        self.assertEqual(local.read_json(self.result())["error"], "ValueError")

    def test_supported_rates_preserved(self):
        for rate in [-30, -20, 0, 20, 50]:
            self.request_id = uuid.uuid4().hex
            self.server.process_request(self.request(rate=rate))
        self.assertEqual([c[2] for c in self.engine.calls], [-30, -20, 0, 20, 50])

    def test_close_removes_pending_answer_text_and_ready(self):
        self.request()
        local.atomic_json(self.path / "ready.json", {"state": "ready"})
        self.server.close()
        self.assertFalse(list(self.path.glob("request-*")))
        self.assertFalse((self.path / "ready.json").exists())
        self.assertEqual(local.read_json(self.path / "status.json")["state"], "stopped")

    def test_close_after_fatal_error_preserves_error_status(self):
        self.server.status("error", "RuntimeError")
        self.server.close(preserve_status=True)
        self.assertEqual(local.read_json(self.path / "status.json")["state"], "error")
        self.assertEqual(local.read_json(self.path / "ready.json")["state"], "error")

    def test_ready_json_alone_is_sufficient_for_client(self):
        self.server.status("ready")
        value = local.read_json(self.path / "ready.json")
        self.assertEqual(value["state"], "ready")
        self.assertEqual(value["pid"], os.getpid())
        self.assertEqual(value["voices"], ["local-tw-sweet"])


class PureTests(unittest.TestCase):
    def test_starting_precedes_loader_and_fatal_error_remains_readable(self):
        with tempfile.TemporaryDirectory(dir=RUN) as folder:
            workspace = Path(folder).resolve()
            state, model = workspace / "local-voice", workspace / "model"
            model.mkdir()
            profiles = workspace / "profiles.json"
            local.atomic_json(profiles, {"profiles": [{"id": "local-tw-sweet", "instruct": "成年自然女声", "seed": 1}]})
            observed = []
            def fail_loader(*args):
                observed.append(local.read_json(state / "ready.json"))
                raise ValueError("PRIVATE loader details")
            args = ["worker", "--workspace", str(workspace), "--state-dir", str(state),
                    "--model-path", str(model), "--profiles-path", str(profiles), "--parent-pid", str(os.getpid())]
            with patch.object(sys, "argv", args), patch.object(local, "QwenEngine", side_effect=fail_loader):
                self.assertEqual(local.main(), 1)
            self.assertEqual(observed[0]["state"], "starting")
            self.assertEqual(observed[0]["pid"], os.getpid())
            result = local.read_json(state / "ready.json")
            self.assertEqual(result["state"], "error")
            self.assertEqual(result["error"], "ValueError")
            self.assertNotIn("PRIVATE", str(result))

    def test_uuid_strict_and_path_independent(self):
        good = uuid.uuid4().hex
        self.assertTrue(local.is_uuid(good))
        for value in [None, 1, good.upper(), "../" + good, str(uuid.UUID(hex=good)), "x" * 36]:
            self.assertFalse(local.is_uuid(value))

    def test_sentence_splitting_preserves_every_character(self):
        for text in ["你好。我们继续！完成？", " ", "甲" * 10000, "一段话。\n" * 1000,
                     "a " * 300, "最后一个字😊", "\n" * 500]:
            parts = local.split_text(text)
            self.assertEqual("".join(parts), text)
            self.assertTrue(all(0 < len(part) <= 220 for part in parts))

    def test_sentence_split_prefers_complete_sentence(self):
        text = "甲" * 100 + "。" + "乙" * 200
        self.assertEqual(local.split_text(text)[0], "甲" * 100 + "。")

    def test_original_design_profiles_and_seeds_validated(self):
        with tempfile.TemporaryDirectory(dir=RUN) as folder:
            workspace = Path(folder).resolve()
            profile = {"id": "local-tw-sweet", "instruct": "成年台湾女性，自然轻甜。", "seed": 20260908}
            filename = workspace / "profiles.json"
            local.atomic_json(filename, {"profiles": [profile]})
            self.assertIn("local-tw-sweet", local.load_profiles(workspace, filename))
            for change in [{"reference_audio": "https://example.test/a.wav"}, {"seed": True},
                           {"instruct": ""}, {"id": "../bad"}, {"model": "remote"}, {"seed": -1}]:
                local.atomic_json(filename, {"profiles": [dict(profile, **change)]})
                with self.subTest(change=list(change)), self.assertRaises((ValueError, FileNotFoundError, OSError)):
                    local.load_profiles(workspace, filename)

    def test_outside_workspace_rejected(self):
        with self.assertRaises(ValueError):
            local.inside(ROOT, ROOT.parent, must_exist=True)


class CancellationTests(unittest.TestCase):
    def test_injection_reaches_talker_even_when_qwen_outer_drops_kwargs(self):
        class Talker:
            def generate(self, **kwargs):
                self.actual = kwargs
                for criterion in kwargs["stopping_criteria"]:
                    criterion(None, None)
                return "done"
        class Outer:
            def generate(self, **kwargs):
                return self.talker.generate(max_new_tokens=2048)  # official dropped kwargs
        outer, checks = Outer(), []
        outer.talker = Talker()
        with local.inject_cancellation(outer.talker, lambda: checks.append(1), object, list):
            self.assertEqual(outer.generate(stopping_criteria="ignored upstream"), "done")
        self.assertEqual(len(checks), 2)
        self.assertNotIn("generate", vars(outer.talker))

    def test_cancellation_unwinds_before_decode_and_restores_method(self):
        class Talker:
            def generate(self, **kwargs):
                for i in range(8):
                    kwargs["stopping_criteria"][0](None, None)
                self.decode_reached = True
        talker = Talker()
        checks = []
        def check():
            checks.append(1)
            if len(checks) == 3:
                raise local.Cancelled()
        with self.assertRaises(local.Cancelled):
            with local.inject_cancellation(talker, check, object, list):
                talker.generate()
        self.assertFalse(hasattr(talker, "decode_reached"))
        self.assertNotIn("generate", vars(talker))

    def test_existing_instance_method_and_criteria_restored(self):
        class Talker:
            pass
        talker = Talker()
        original = lambda **kwargs: len(kwargs["stopping_criteria"])
        talker.generate = original
        with local.inject_cancellation(talker, lambda: None, object, list):
            self.assertEqual(talker.generate(stopping_criteria=[object()]), 2)
        self.assertIs(talker.generate, original)

    def test_real_windows_process_handle_detects_exit(self):
        flags = subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0
        process = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(2)"], creationflags=flags)
        watch = local.ProcessWatch(process.pid)
        try:
            self.assertTrue(watch.alive())
            process.terminate()
            process.wait(timeout=5)
            self.assertFalse(watch.alive())
        finally:
            if process.poll() is None:
                process.kill()
            watch.close()


if __name__ == "__main__":
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    (RUN / "result.json").write_text(json.dumps({
        "tests": result.testsRun, "failures": len(result.failures), "errors": len(result.errors),
        "passed": result.wasSuccessful(), "boundary": "Fake model; no GPU, network, microphone or playback. Windows process handles tested."}, indent=2), encoding="utf-8")
    raise SystemExit(not result.wasSuccessful())
