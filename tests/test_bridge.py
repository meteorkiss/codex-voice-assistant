"""Offline behavioral checks. No tool call sends a real Codex message."""
import concurrent.futures
import json
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUN_ROOT = PROJECT_ROOT / 'work' / 'tests' / 'bridge'
RUN_ROOT.mkdir(parents=True, exist_ok=True)
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT / 'src'))
import codex_bridge as bridge
TEST_THREAD = str(uuid.uuid4())


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.paths = [bridge.PIPE_PREFIX + 'codex-browser-use-' + str(uuid.uuid4()) for _ in range(3)]
        self.capabilities = {'tools': [{'namespace': 'codex_app', 'name': name}
                                       for name in ('read_thread', 'send_message_to_thread')]}
        env = patch.dict(os.environ, {}, clear=True)
        env.start()
        self.addCleanup(env.stop)

    def test_standalone_discovers_app_tools_not_browser_endpoints(self):
        def response(path, method, params, **kwargs):
            self.assertEqual(method, 'tools/list')
            self.assertFalse(kwargs.get('mutation', False))
            return self.capabilities if path == self.paths[1] else {'tools': [{'namespace': 'browser', 'name': 'read_thread'}]}
        with patch.object(bridge.os, 'listdir', return_value=[p[len(bridge.PIPE_PREFIX):] for p in self.paths] + ['unrelated']), \
                patch.object(bridge, 'pipe_request', side_effect=response) as calls:
            self.assertEqual(bridge.discover_pipe(), self.paths[1])
            self.assertEqual(calls.call_count, 3)

    def test_ambiguous_app_endpoints_never_choose_first(self):
        with patch.object(bridge.os, 'listdir', return_value=[p[len(bridge.PIPE_PREFIX):] for p in self.paths]), \
                patch.object(bridge, 'pipe_request', return_value=self.capabilities):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.discover_pipe()
            self.assertEqual(error.exception.code, 'connection_ambiguous')

    def test_fresh_hint_and_explicit_endpoint_do_not_enumerate(self):
        for explicit in (False, True):
            with self.subTest(explicit=explicit), patch.dict(os.environ, {'CODEX_APP_TOOLS_PIPE_PATH': self.paths[0]}), \
                    patch.object(bridge.os, 'listdir') as listing, \
                    patch.object(bridge, 'pipe_request', return_value=self.capabilities):
                self.assertEqual(bridge.discover_pipe(self.paths[1] if explicit else None), self.paths[1] if explicit else self.paths[0])
                listing.assert_not_called()

    def test_stale_inherited_hint_falls_back_only_before_dispatch(self):
        def response(path, *args, **kwargs):
            if path == self.paths[0]:
                raise bridge.BridgeError('connection_unavailable', 'expired hint')
            return self.capabilities
        with patch.dict(os.environ, {'CODEX_APP_TOOLS_PIPE_PATH': self.paths[0]}), \
                patch.object(bridge.os, 'listdir', return_value=[self.paths[1][len(bridge.PIPE_PREFIX):]]), \
                patch.object(bridge, 'pipe_request', side_effect=response):
            self.assertEqual(bridge.discover_pipe(), self.paths[1])

    def test_explicit_dead_or_untrusted_hint_never_falls_back(self):
        for explicit, code in ((True, 'connection_unavailable'), (False, 'untrusted_connection')):
            with self.subTest(code=code), patch.dict(os.environ, {'CODEX_APP_TOOLS_PIPE_PATH': self.paths[0]}), \
                    patch.object(bridge.os, 'listdir') as listing, \
                    patch.object(bridge, 'pipe_request', side_effect=bridge.BridgeError(code, 'blocked')):
                with self.assertRaises(bridge.BridgeError):
                    bridge.discover_pipe(self.paths[0] if explicit else None)
                listing.assert_not_called()

    def test_no_endpoint_and_excess_candidates_are_bounded(self):
        for count, code in ((0, 'codex_not_running'), (17, 'connection_ambiguous')):
            with self.subTest(count=count), patch.object(bridge.os, 'listdir', return_value=['codex-browser-use-'+str(uuid.uuid4()) for _ in range(count)]), \
                    patch.object(bridge, 'pipe_request') as call:
                with self.assertRaises(bridge.BridgeError) as error:
                    bridge.discover_pipe()
                self.assertEqual(error.exception.code, code)
                call.assert_not_called()

    def test_unknown_second_endpoint_blocks_unique_assumption(self):
        def response(path, *args, **kwargs):
            if path == self.paths[0]:
                raise bridge.BridgeError('connection_timeout', 'unresolved endpoint')
            return self.capabilities
        with patch.object(bridge.os, 'listdir', return_value=[p[len(bridge.PIPE_PREFIX):] for p in self.paths[:2]]), \
                patch.object(bridge, 'pipe_request', side_effect=response):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.discover_pipe()
            self.assertEqual(error.exception.code, 'connection_timeout')

    def test_malformed_capabilities_are_rejected(self):
        for value in (None, [], {}, {'tools': None}, {'tools': [None, 'x', {}]}):
            with self.subTest(value=value), patch.object(bridge, 'pipe_request', return_value=value):
                with self.assertRaises(bridge.BridgeError) as error:
                    bridge.probe_app_pipe(self.paths[0])
                self.assertEqual(error.exception.code, 'unsupported_app_version')

    def test_untrusted_owner_is_rejected_before_any_write(self):
        from unittest.mock import mock_open
        opened = mock_open()
        with patch('builtins.open', opened), \
                patch.object(bridge, 'verify_pipe_owner', side_effect=bridge.BridgeError('untrusted_connection', 'wrong owner')) as owner:
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.pipe_request(self.paths[0], 'tools/call', {}, mutation=True)
            self.assertEqual(error.exception.code, 'untrusted_connection')
            self.assertFalse(error.exception.uncertain)
            owner.assert_called_once()
            opened().write.assert_not_called()


class SendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=RUN_ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.request_id = str(uuid.uuid4())
        state = patch.object(bridge, 'binding_state', return_value={
            'threadId': TEST_THREAD, 'state': 'active', 'archived': False})
        state.start()
        self.addCleanup(state.stop)

    def send(self, text='中文与引号 " $() ` 保持原文', request_id=None):
        return bridge.send_once('unused', TEST_THREAD, text,
                                request_id or self.request_id, self.tmp.name)

    def test_same_request_accepted_only_once(self):
        with patch.object(bridge, 'app_tool', return_value={'threadId': TEST_THREAD}) as call:
            one = self.send()
            two = self.send()
            self.assertTrue(one['accepted'])
            self.assertTrue(two['duplicateSuppressed'])
            self.assertEqual(call.call_count, 1)
            arguments = call.call_args.args[2]
            self.assertEqual(set(arguments), {'threadId', 'hostId', 'prompt'})
            self.assertIn('$()', arguments['prompt'])

    def test_archive_at_actual_dispatch_is_definitely_rejected_and_never_sent(self):
        with patch.object(bridge, 'binding_state', return_value={
                'threadId': TEST_THREAD, 'state': 'archived', 'archived': True}), \
                patch.object(bridge, 'app_tool') as call:
            with self.assertRaises(bridge.BridgeError) as error:
                self.send()
        self.assertEqual(error.exception.code, 'task_archived')
        self.assertFalse(error.exception.uncertain)
        call.assert_not_called()
        with sqlite3.connect(Path(self.tmp.name) / 'send-ledger.sqlite3') as db:
            self.assertEqual(db.execute('SELECT state FROM sends WHERE request_id=?',
                                        (self.request_id,)).fetchone()[0], 'rejected')
        db.close()
        with patch.object(bridge, 'app_tool') as call:
            with self.assertRaises(bridge.BridgeError) as duplicate:
                self.send()
        self.assertEqual(duplicate.exception.code, 'duplicate_suppressed')
        self.assertFalse(duplicate.exception.uncertain)
        call.assert_not_called()

    def test_uncertain_send_never_replayed(self):
        with patch.object(bridge, 'app_tool', side_effect=bridge.BridgeError('send_unknown', 'timeout', True)) as call:
            with self.assertRaises(bridge.BridgeError) as first:
                self.send()
            with self.assertRaises(bridge.BridgeError) as second:
                self.send()
            self.assertTrue(first.exception.uncertain)
            self.assertEqual(second.exception.code, 'duplicate_suppressed')
            self.assertTrue(second.exception.uncertain)
            self.assertEqual(call.call_count, 1)

    def test_request_id_content_conflict(self):
        with patch.object(bridge, 'app_tool', return_value={'threadId': TEST_THREAD}) as call:
            self.send('第一句')
            with self.assertRaises(bridge.BridgeError) as conflict:
                self.send('第二句')
            self.assertEqual(conflict.exception.code, 'request_id_conflict')
            self.assertEqual(call.call_count, 1)

    def test_two_concurrent_clicks_produce_one_send(self):
        def slow(*args, **kwargs):
            time.sleep(.12)
            return {'threadId': TEST_THREAD}
        def invoke():
            try:
                return self.send()
            except bridge.BridgeError as exc:
                return exc.code
        with patch.object(bridge, 'app_tool', side_effect=slow) as call:
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                values = list(pool.map(lambda _: invoke(), range(2)))
            self.assertEqual(call.call_count, 1)
            self.assertEqual(sum(isinstance(x, dict) and x['accepted'] for x in values), 1)

    def test_unknown_after_acceptance_processing_blocks_retry(self):
        with patch.object(bridge, 'app_tool', side_effect=ValueError('malformed acceptance')) as call:
            with self.assertRaises(bridge.BridgeError) as first:
                self.send()
            self.assertTrue(first.exception.uncertain)
            with self.assertRaises(bridge.BridgeError):
                self.send()
            self.assertEqual(call.call_count, 1)

    def test_missing_or_nonboolean_success_is_unknown_and_cannot_replay(self):
        for reply in ({}, {'success': None}, {'success': 'false'}, {'success': 0},
                      {'success': 1}, [], None):
            with self.subTest(reply=reply):
                request_id = str(uuid.uuid4())
                with patch.object(bridge, 'pipe_request', return_value=reply) as call:
                    with self.assertRaises(bridge.BridgeError) as first:
                        self.send(request_id=request_id)
                    self.assertEqual(first.exception.code, 'send_unknown')
                    self.assertTrue(first.exception.uncertain)
                    with self.assertRaises(bridge.BridgeError) as second:
                        self.send(request_id=request_id)
                    self.assertEqual(second.exception.code, 'duplicate_suppressed')
                    self.assertTrue(second.exception.uncertain)
                    self.assertEqual(call.call_count, 1)
                with sqlite3.connect(Path(self.tmp.name) / 'send-ledger.sqlite3') as db:
                    self.assertEqual(db.execute('SELECT state FROM sends WHERE request_id=?',
                                                (request_id,)).fetchone()[0], 'unknown')
                db.close()

    def test_explicit_rejection_is_definite_and_duplicate_still_blocked(self):
        with patch.object(bridge, 'pipe_request', return_value={'success': False}) as call:
            with self.assertRaises(bridge.BridgeError) as first:
                self.send()
            self.assertEqual(first.exception.code, 'app_rejected')
            self.assertFalse(first.exception.uncertain)
            with self.assertRaises(bridge.BridgeError) as second:
                self.send()
            self.assertFalse(second.exception.uncertain)
            self.assertEqual(call.call_count, 1)

    def test_success_without_matching_receipt_stays_unknown(self):
        for body in ({}, {'threadId': str(uuid.uuid4())},
                     {'threadId': TEST_THREAD, 'hostId': 'remote'}, []):
            with self.subTest(body=body):
                request_id = str(uuid.uuid4())
                response = {'success': True, 'contentItems':
                            [{'type': 'inputText', 'text': json.dumps(body)}]}
                with patch.object(bridge, 'pipe_request', return_value=response) as call:
                    with self.assertRaises(bridge.BridgeError) as first:
                        self.send(request_id=request_id)
                    self.assertTrue(first.exception.uncertain)
                    with self.assertRaises(bridge.BridgeError):
                        self.send(request_id=request_id)
                    self.assertEqual(call.call_count, 1)

    def test_existing_pending_ledger_record_blocks_send_after_restart(self):
        with patch.object(bridge, 'app_tool', side_effect=bridge.BridgeError('send_unknown', 'unknown', True)):
            with self.assertRaises(bridge.BridgeError):
                self.send()
        with sqlite3.connect(Path(self.tmp.name) / 'send-ledger.sqlite3') as db:
            db.execute('UPDATE sends SET state="pending"')
        db.close()
        with patch.object(bridge, 'app_tool') as call:
            with self.assertRaises(bridge.BridgeError) as error:
                self.send()
            self.assertTrue(error.exception.uncertain)
            call.assert_not_called()

    def test_ledger_update_failure_keeps_unknown_and_pending_retry_guard(self):
        real_connect = sqlite3.connect

        class FailingUpdate:
            def __init__(self, *args, **kwargs):
                self.connection = real_connect(*args, **kwargs)

            def execute(self, statement, *args):
                if statement.startswith('UPDATE sends'):
                    raise sqlite3.OperationalError('simulated disk failure after dispatch')
                return self.connection.execute(statement, *args)

            def __getattr__(self, name):
                return getattr(self.connection, name)

        with patch.object(bridge.sqlite3, 'connect', side_effect=FailingUpdate), \
                patch.object(bridge, 'app_tool', side_effect=bridge.BridgeError('send_unknown', 'unknown', True)):
            with self.assertRaises(bridge.BridgeError) as first:
                self.send()
            self.assertEqual(first.exception.code, 'send_unknown')
            self.assertTrue(first.exception.uncertain)
        with patch.object(bridge, 'app_tool') as call:
            with self.assertRaises(bridge.BridgeError) as second:
                self.send()
            self.assertTrue(second.exception.uncertain)
            self.assertEqual(second.exception.code, 'duplicate_suppressed')
            call.assert_not_called()

    def test_archive_rejection_never_relabels_unknown_or_pending_as_unsent(self):
        for stored_state in ('unknown', 'pending'):
            with self.subTest(state=stored_state):
                request_id = str(uuid.uuid4())
                with patch.object(bridge, 'app_tool', side_effect=bridge.BridgeError('send_unknown', 'unknown', True)):
                    with self.assertRaises(bridge.BridgeError):
                        self.send('原始草稿', request_id)
                with sqlite3.connect(Path(self.tmp.name) / 'send-ledger.sqlite3') as db:
                    db.execute('UPDATE sends SET state=? WHERE request_id=?', (stored_state, request_id))
                db.close()
                with patch.object(bridge, 'binding_state') as state, \
                        patch.object(bridge, 'discover_pipe') as discover, \
                        patch.object(bridge, 'send_once') as send:
                    with self.assertRaises(bridge.BridgeError) as error:
                        bridge.handle({'action': 'send', 'threadId': TEST_THREAD, 'text': '原始草稿',
                                       'requestId': request_id, 'stateDir': self.tmp.name})
                self.assertEqual(error.exception.code, 'duplicate_suppressed')
                self.assertTrue(error.exception.uncertain)
                for operation in (state, discover, send):
                    operation.assert_not_called()

    def test_accepted_ledger_receipt_still_returns_without_new_send_or_archive_check(self):
        with patch.object(bridge, 'app_tool', return_value={'threadId': TEST_THREAD}):
            self.send('原文')
        with patch.object(bridge, 'binding_state') as state, \
                patch.object(bridge, 'discover_pipe') as discover, patch.object(bridge, 'send_once') as send:
            out = bridge.handle({'action': 'send', 'threadId': TEST_THREAD, 'text': '原文',
                                 'requestId': self.request_id, 'stateDir': self.tmp.name})
        self.assertTrue(out['accepted'])
        self.assertTrue(out['duplicateSuppressed'])
        for operation in (state, discover, send):
            operation.assert_not_called()

    def test_unreadable_send_ledger_blocks_before_state_check_and_stays_uncertain(self):
        (Path(self.tmp.name) / 'send-ledger.sqlite3').write_bytes(b'not sqlite')
        with patch.object(bridge, 'binding_state') as state, patch.object(bridge, 'send_once') as send:
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.handle({'action': 'send', 'threadId': TEST_THREAD, 'text': '原文',
                               'requestId': self.request_id, 'stateDir': self.tmp.name})
        self.assertEqual(error.exception.code, 'send_ledger_unavailable')
        self.assertTrue(error.exception.uncertain)
        state.assert_not_called()
        send.assert_not_called()


class ReadTests(unittest.TestCase):
    def setUp(self):
        # These tests isolate App Tools answer parsing; the full SQLite-backed
        # archive validation is exercised separately in BootstrapTests below.
        state = patch.object(bridge, 'binding_state', return_value={
            'threadId': TEST_THREAD, 'state': 'active', 'archived': False})
        state.start()
        self.addCleanup(state.stop)
        ledger = patch.object(bridge, 'existing_send_result', return_value=None)
        ledger.start()
        self.addCleanup(ledger.stop)

    def test_only_last_final_from_completed_turn_is_latest(self):
        result = {
            'thread': {'id': TEST_THREAD, 'kind': 'codex', 'hostId': 'local', 'status': {'type': 'active'}},
            'turns': [
                {'id': 'active', 'status': 'inProgress', 'items': [{'type': 'agentMessage', 'phase': 'final_answer', 'text': 'unfinished'}]},
                {'id': 'done', 'status': 'completed', 'items': [
                    {'type': 'reasoning', 'text': 'private'},
                    {'type': 'agentMessage', 'phase': 'final_answer', 'text': 'earlier question'},
                    {'type': 'agentMessage', 'phase': 'commentary', 'text': 'progress'},
                    {'type': 'agentMessage', 'phase': 'final_answer', 'text': '正确答案'}]},
            ]}
        with patch.object(bridge, 'app_tool', return_value=result), patch.object(bridge, 'rollout_path', return_value=None):
            out = bridge.read_task('unused', TEST_THREAD)
        self.assertEqual(out['lastAssistantText'], '正确答案')
        self.assertEqual(out['status'], 'active')
        self.assertFalse(out['archived'])
        self.assertEqual(out['bindingState'], 'active')
        self.assertNotIn('private', json.dumps(out))

    def test_reject_other_thread(self):
        with patch.object(bridge, 'app_tool', return_value={'thread': {'id': str(uuid.uuid4())}}):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.read_task('unused', TEST_THREAD)
        self.assertEqual(error.exception.code, 'wrong_target')

    def test_truncated_final_is_marked_for_explicit_readback(self):
        result = {'thread': {'id': TEST_THREAD, 'kind': 'codex', 'hostId': 'local'},
                  'turns': [{'id': 'done', 'status': 'completed', 'items': [
                      {'type': 'agentMessage', 'phase': 'final_answer', 'text': 'partial', 'truncated': True}]}]}
        with patch.object(bridge, 'app_tool', return_value=result), patch.object(bridge, 'rollout_path', return_value=None):
            out = bridge.read_task('unused', TEST_THREAD)
        self.assertTrue(out['lastAssistantTextTruncated'])

    def test_native_codex_final_can_reach_or_exceed_tool_output_limit(self):
        # Current App Tools mJi copies agentMessage.text directly; its max-output
        # option truncates tool outputs, not Codex final answers. A length-only
        # rule would incorrectly reject complete responses at this boundary.
        for text in ('答' * 20000, '答' * 20001 + '完整结尾', '🙂' * 10000):
            with self.subTest(length=len(text)):
                result = {'thread': {'id': TEST_THREAD, 'kind': 'codex', 'hostId': 'local'},
                          'turns': [{'id': 'done', 'status': 'completed', 'items': [
                              {'type': 'agentMessage', 'phase': 'final_answer', 'text': text}]}]}
                with patch.object(bridge, 'app_tool', return_value=result), patch.object(bridge, 'rollout_path', return_value=None):
                    out = bridge.read_task('unused', TEST_THREAD)
                self.assertEqual(out['lastAssistantText'], text)
                self.assertFalse(out['lastAssistantTextTruncated'])

    def test_reject_remote_or_non_codex_before_mutation(self):
        for host, kind in [('remote', 'codex'), ('local', 'chatgpt')]:
            result = {'thread': {'id': TEST_THREAD, 'kind': kind, 'hostId': host}}
            with self.subTest(host=host, kind=kind), patch.object(bridge, 'discover_pipe', return_value='unused'), \
                    patch.object(bridge, 'app_tool', return_value=result) as call, \
                    patch.object(bridge, 'send_once') as send:
                with self.assertRaises(bridge.BridgeError) as error:
                    bridge.handle({'action': 'send', 'threadId': TEST_THREAD, 'text': 'test',
                                   'requestId': str(uuid.uuid4())})
                self.assertEqual(error.exception.code, 'wrong_target')
                self.assertEqual(call.call_args.args[1], 'read_thread')
                self.assertEqual(call.call_args.args[3], TEST_THREAD)
                send.assert_not_called()

    def test_read_uses_only_explicit_source_and_target(self):
        with patch.object(bridge, 'discover_pipe', return_value='unused'), \
                patch.object(bridge, 'rollout_path', return_value=None), \
                patch.object(bridge, 'app_tool', return_value={
                    'thread': {'id': TEST_THREAD, 'kind': 'codex', 'hostId': 'local'}}) as call:
            out = bridge.handle({'action': 'read', 'threadId': TEST_THREAD})
        self.assertEqual(out['threadId'], TEST_THREAD)
        self.assertEqual(call.call_args.args[2]['threadId'], TEST_THREAD)
        self.assertEqual(call.call_args.args[3], TEST_THREAD)


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=RUN_ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = patch.dict(os.environ, {'CODEX_HOME': str(self.root)})
        self.env.start()
        self.addCleanup(self.env.stop)
        (self.root / 'sessions').mkdir()

    def index(self, name='state_5.sqlite', extra=''):
        db = sqlite3.connect(self.root / name)
        db.execute('CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, cwd TEXT, rollout_path TEXT, '
                   'archived INTEGER, source TEXT, updated_at INTEGER, agent_path TEXT, '
                   'thread_source TEXT' + extra + ')')
        db.commit()
        return db

    def add_task(self, db, **overrides):
        task_id = str(uuid.uuid4())
        path = self.root / 'sessions' / ('rollout-test-' + task_id + '.jsonl')
        path.touch()
        row = {'id': task_id, 'title': '测试任务', 'cwd': str(self.root), 'rollout_path': str(path),
               'archived': 0, 'source': 'vscode', 'updated_at': 1,
               'agent_path': None, 'thread_source': 'user'}
        row.update(overrides)
        db.execute('INSERT INTO threads (' + ','.join(row) + ') VALUES (' +
                   ','.join('?' for _ in row) + ')', tuple(row.values()))
        db.commit()
        return row

    def test_no_task_fails_before_discovery_for_targeted_actions(self):
        for action in ('read', 'binding-state', 'send', 'open', 'create', 'create-status', 'manage'):
            for value in (None, '', '  '):
                with self.subTest(action=action, value=value), patch.object(bridge, 'discover_pipe') as call:
                    request = {'action': action}
                    if value is not None:
                        request['threadId'] = value
                    with self.assertRaises(bridge.BridgeError) as error:
                        bridge.handle(request)
                    self.assertEqual(error.exception.code, 'thread_required')
                    call.assert_not_called()

    def test_binding_state_invalid_id_fails_before_any_index_or_connection_access(self):
        for value in (None, '', 'not-a-uuid', [], {}):
            with self.subTest(value=value), patch.object(bridge, 'codex_home') as home, \
                    patch.object(bridge, 'discover_pipe') as discover, patch.object(bridge, 'app_tool') as call:
                with self.assertRaises(bridge.BridgeError):
                    bridge.handle({'action': 'binding-state', 'threadId': value})
                for operation in (home, discover, call):
                    operation.assert_not_called()

    def test_binding_state_observes_live_wal_archive_and_delete_without_pipe_or_content(self):
        db = self.index()
        self.addCleanup(db.close)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA wal_autocheckpoint=0')
        row = self.add_task(db)
        with patch.object(bridge, 'discover_pipe') as discover, patch.object(bridge, 'app_tool') as call, \
                patch.object(bridge, 'rollout_path') as paths, patch.object(bridge, 'is_subagent') as content:
            for expected, archived in (('active', 0), ('archived', 1), ('active', 0)):
                db.execute('UPDATE threads SET archived=? WHERE id=?', (archived, row['id']))
                db.commit()
                before = db.execute('SELECT * FROM threads').fetchall()
                out = bridge.handle({'action': 'binding-state', 'threadId': row['id']})
                self.assertEqual(out, {'threadId': row['id'], 'state': expected, 'archived': bool(archived)})
                self.assertEqual(db.execute('SELECT * FROM threads').fetchall(), before)
            db.execute('DELETE FROM threads WHERE id=?', (row['id'],))
            db.commit()
            self.assertEqual(bridge.handle({'action': 'binding-state', 'threadId': row['id']}),
                             {'threadId': row['id'], 'state': 'missing', 'archived': False})
        for operation in (discover, call, paths, content):
            operation.assert_not_called()

    def test_binding_state_does_not_infer_archive_from_missing_or_moved_rollout(self):
        with self.index() as db:
            row = self.add_task(db)
        db.close()
        Path(row['rollout_path']).unlink()
        out = bridge.handle({'action': 'binding-state', 'threadId': row['id']})
        self.assertEqual((out['state'], out['archived']), ('active', False))

    def test_binding_state_rejects_nonlocal_or_child_identity_even_when_archived(self):
        with self.index(extra=', host_id TEXT DEFAULT "local", kind TEXT DEFAULT "codex", parent_thread_id TEXT') as db:
            for values in ({'agent_path': '/root/child'}, {'parent_thread_id': str(uuid.uuid4())},
                           {'source': '{"subagent":{}}'}, {'thread_source': 'subagent'},
                           {'source': 'remote'}, {'host_id': 'remote'}, {'kind': 'chatgpt'},
                           {'cwd': '\\\\server\\share'}, {'cwd': 'relative'}):
                for archived in (0, 1):
                    with self.subTest(values=values, archived=archived):
                        row = self.add_task(db, archived=archived, **values)
                        with self.assertRaises(bridge.BridgeError) as error:
                            bridge.handle({'action': 'binding-state', 'threadId': row['id']})
                        self.assertEqual(error.exception.code, 'wrong_target')
        db.close()

    def test_binding_state_requires_explicit_boolean_archive_value(self):
        with self.index() as db:
            for value in (None, 2, -1, 'false', 'unknown'):
                with self.subTest(value=value):
                    row = self.add_task(db, archived=value)
                    with self.assertRaises(bridge.BridgeError) as error:
                        bridge.handle({'action': 'binding-state', 'threadId': row['id']})
                    self.assertEqual(error.exception.code, 'index_unavailable')
        db.close()

    def test_binding_state_missing_index_is_an_error_not_archived_or_missing_task(self):
        with self.assertRaises(bridge.BridgeError) as error:
            bridge.handle({'action': 'binding-state', 'threadId': TEST_THREAD})
        self.assertEqual(error.exception.code, 'index_not_found')
        self.assertEqual(list(self.root.glob('state_*.sqlite')), [])

    def test_binding_state_newest_schema_corruption_and_permission_errors_never_fall_back(self):
        with self.index() as db:
            self.add_task(db, id=TEST_THREAD, archived=1)
        db.close()
        newer = self.root / 'state_6.sqlite'
        with sqlite3.connect(newer) as db:
            db.execute('CREATE TABLE threads (id TEXT)')
        db.close()
        with self.assertRaises(bridge.BridgeError) as error:
            bridge.handle({'action': 'binding-state', 'threadId': TEST_THREAD})
        self.assertEqual(error.exception.code, 'unsupported_index_schema')
        newer.write_bytes(b'not sqlite')
        with self.assertRaises(bridge.BridgeError) as error:
            bridge.handle({'action': 'binding-state', 'threadId': TEST_THREAD})
        self.assertEqual(error.exception.code, 'index_unavailable')
        with patch.object(bridge.sqlite3, 'connect', side_effect=PermissionError('denied')):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.handle({'action': 'binding-state', 'threadId': TEST_THREAD})
        self.assertEqual(error.exception.code, 'index_unavailable')

    def test_read_returns_reliable_archive_state_without_forbidding_recovery_read(self):
        with self.index() as db:
            row = self.add_task(db)
            result = {'thread': {'id': row['id'], 'kind': 'codex', 'hostId': 'local'}}
            with patch.object(bridge, 'app_tool', return_value=result) as call, \
                    patch.object(bridge, 'rollout_path', return_value=None):
                for archived in (0, 1):
                    db.execute('UPDATE threads SET archived=? WHERE id=?', (archived, row['id']))
                    db.commit()
                    out = bridge.read_task('unused', row['id'])
                    self.assertEqual(out['archived'], bool(archived))
                    self.assertEqual(out['bindingState'], 'archived' if archived else 'active')
                self.assertTrue(all(item.args[1] == 'read_thread' for item in call.call_args_list))
        db.close()

    def test_read_does_not_guess_archive_when_index_is_missing_or_unavailable(self):
        db = self.index()
        db.close()
        result = {'thread': {'id': TEST_THREAD, 'kind': 'codex', 'hostId': 'local'}}
        with patch.object(bridge, 'app_tool', return_value=result):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.read_task('unused', TEST_THREAD)
            self.assertEqual(error.exception.code, 'task_unavailable')
        (self.root / 'state_5.sqlite').write_bytes(b'not sqlite')
        with patch.object(bridge, 'app_tool', return_value=result):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.read_task('unused', TEST_THREAD)
            self.assertEqual(error.exception.code, 'index_unavailable')

    def test_send_archived_missing_or_unverifiable_target_is_definitely_blocked_before_pipe(self):
        with self.index() as db:
            archived = self.add_task(db, archived=1)
        db.close()
        for task_id, code in ((archived['id'], 'task_archived'), (TEST_THREAD, 'task_unavailable')):
            with self.subTest(code=code), patch.object(bridge, 'discover_pipe') as discover, \
                    patch.object(bridge, 'send_once') as send:
                with self.assertRaises(bridge.BridgeError) as error:
                    bridge.handle({'action': 'send', 'threadId': task_id, 'text': '未发送的草稿',
                                   'requestId': str(uuid.uuid4()), 'stateDir': str(self.root)})
                self.assertEqual(error.exception.code, code)
                self.assertFalse(error.exception.uncertain)
                discover.assert_not_called()
                send.assert_not_called()
        (self.root / 'state_5.sqlite').write_bytes(b'not sqlite')
        with patch.object(bridge, 'send_once') as send:
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.handle({'action': 'send', 'threadId': TEST_THREAD, 'text': '未发送的草稿',
                               'requestId': str(uuid.uuid4()), 'stateDir': str(self.root)})
        self.assertEqual(error.exception.code, 'task_unavailable')
        self.assertFalse(error.exception.uncertain)
        send.assert_not_called()
        self.assertFalse((self.root / 'send-ledger.sqlite3').exists())

    def test_send_rechecks_archive_after_live_read_before_send_once(self):
        with self.index() as db:
            row = self.add_task(db)
        db.close()

        def archive_during_read(*args, **kwargs):
            with sqlite3.connect(self.root / 'state_5.sqlite') as changed:
                changed.execute('UPDATE threads SET archived=1 WHERE id=?', (row['id'],))
            changed.close()
            return {'thread': {'id': row['id'], 'kind': 'codex', 'hostId': 'local'}}

        with patch.object(bridge, 'discover_pipe', return_value='unused'), \
                patch.object(bridge, 'app_tool', side_effect=archive_during_read), \
                patch.object(bridge, 'rollout_path', return_value=None), \
                patch.object(bridge, 'send_once') as send:
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.handle({'action': 'send', 'threadId': row['id'], 'text': '未发送的草稿',
                               'requestId': str(uuid.uuid4()), 'stateDir': str(self.root)})
        self.assertEqual(error.exception.code, 'task_archived')
        self.assertFalse(error.exception.uncertain)
        send.assert_not_called()

    def test_send_active_verified_local_target_reaches_send_once(self):
        with self.index() as db:
            row = self.add_task(db)
        db.close()
        result = {'thread': {'id': row['id'], 'kind': 'codex', 'hostId': 'local'}}
        request_id = str(uuid.uuid4())
        with patch.object(bridge, 'discover_pipe', return_value='unused'), \
                patch.object(bridge, 'app_tool', return_value=result), \
                patch.object(bridge, 'rollout_path', return_value=None), \
                patch.object(bridge, 'send_once', return_value={'accepted': True}) as send:
            out = bridge.handle({'action': 'send', 'threadId': row['id'], 'text': '原始草稿',
                                 'requestId': request_id, 'stateDir': str(self.root)})
        self.assertTrue(out['accepted'])
        send.assert_called_once_with('unused', row['id'], '原始草稿', request_id, str(self.root))

    def test_first_launch_lists_candidates_without_pipe_or_source_task(self):
        with self.index() as db:
            row = self.add_task(db, title='含引号 " 与中文')
        db.close()
        with patch.object(bridge, 'discover_pipe') as discover, patch.object(bridge, 'app_tool') as call, \
                patch.object(bridge, 'is_subagent') as content_read:
            out = bridge.handle({'action': 'list'})
        discover.assert_not_called()
        call.assert_not_called()
        content_read.assert_not_called()
        self.assertEqual(len(out['threads']), 1)
        self.assertEqual(out['threads'][0]['threadId'], row['id'])
        self.assertEqual(out['threads'][0]['title'], row['title'])
        self.assertEqual(out['threads'][0]['rolloutPath'], row['rollout_path'])
        self.assertTrue(out['threads'][0]['requiresValidation'])
        self.assertEqual(out['threads'][0]['status'], 'unknown')
        self.assertEqual(out['connectionState'], 'not_checked')

    def test_find_searches_all_local_titles_without_binding_or_pipe(self):
        with self.index() as db:
            self.add_task(db, title='其他测试任务')
            expected = self.add_task(db, title='这个高斯破渐算法用于 V2 的可行性',
                                     cwd=str(self.root / 'another-project'))
        db.close()
        with patch.object(bridge, 'discover_pipe') as discover, patch.object(bridge, 'app_tool') as call, \
                patch.object(bridge, 'read_task') as read, patch.object(bridge, 'is_subagent') as content_read:
            out = bridge.handle({'action': 'find', 'query': '高斯坡建',
                                 'threadId': 'irrelevant-old-binding', 'cwd': str(self.root)})
        for operation in (discover, call, read, content_read):
            operation.assert_not_called()
        self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'phonetic'))
        self.assertEqual(out['totalMatches'], 1)
        self.assertEqual(out['threads'][0]['threadId'], expected['id'])
        self.assertEqual(out['threads'][0]['title'], expected['title'])
        self.assertTrue(out['threads'][0]['requiresValidation'])

    def title_record(self, task_id, title, updated='2026-09-12T06:38:44.2105951Z'):
        return json.dumps({'id': task_id, 'thread_name': title, 'updated_at': updated},
                          ensure_ascii=False) + '\n'

    def test_sidebar_title_shared_by_list_and_keyword_lookup_without_pipe(self):
        with self.index() as db:
            row = self.add_task(db, title='这声伴怎么又不识别声音了。另外我需要验收什么内容')
        db.close()
        title = '声伴 v0.6.17 · 短时连续接话'
        index = self.root / 'session_index.jsonl'
        index.write_text(self.title_record(row['id'], title), encoding='utf-8-sig')
        before = index.read_bytes()
        with patch.object(bridge, 'discover_pipe') as discover, patch.object(bridge, 'app_tool') as call, \
                patch.object(bridge, 'read_task') as read, patch.object(bridge, 'is_subagent') as content_read:
            listing = bridge.handle({'action': 'list'})
            for query in ('6.17', '声伴 6.17', '6.17 声伴', '声伴6.17'):
                result = bridge.handle({'action': 'find', 'query': query})
                self.assertEqual(result['matchType'], 'unique')
                self.assertEqual(result['threads'][0]['threadId'], row['id'])
                self.assertEqual(result['threads'][0]['title'], title)
                self.assertEqual(result['warning'], '')
        for operation in (discover, call, read, content_read):
            operation.assert_not_called()
        self.assertEqual(listing['threads'][0]['title'], title)
        self.assertEqual(listing['threads'][0]['titleSource'], 'session_index')
        self.assertEqual(listing['unsyncedTitleCount'], 0)
        self.assertTrue(listing['titleIndexAvailable'])
        self.assertEqual(index.read_bytes(), before)
        with sqlite3.connect(self.root / 'state_5.sqlite') as db:
            self.assertEqual(db.execute('SELECT title FROM threads').fetchone()[0], row['title'])
        db.close()

    def test_empty_task_names_are_diagnosed_and_prevent_false_unique_auto_bind(self):
        with self.index() as db:
            unnamed = self.add_task(db, title='')
            named = self.add_task(db, title='声伴 v0.6.18 · 语音切换修复')
        db.close()
        with patch.object(bridge, 'discover_pipe') as discover, patch.object(bridge, 'app_tool') as call:
            out = bridge.handle({'action': 'find', 'query': '0.6.18'})
            self.assertEqual(out['threads'][0]['threadId'], named['id'])
            self.assertTrue(out['requiresConfirmation'])
            self.assertEqual(out['missingTitleCount'], 1)
            self.assertIn('名称为空', out['warning'])
            missing = bridge.handle({'action': 'find', 'query': '免唤醒架构实现'})
            self.assertEqual(missing['matchType'], 'none')
            self.assertEqual(missing['missingTitleCount'], 1)
            # Restoring the actual title restores discoverability without
            # changing the task ID, archive boundary or guessing from content.
            (self.root / 'session_index.jsonl').write_text(self.title_record(
                unnamed['id'], '声伴 v0.6.18 · 免唤醒架构与实现'), encoding='utf-8')
            fixed = bridge.handle({'action': 'find', 'query': '申办0.6.18免唤醒架构实现'})
            self.assertEqual(fixed['threads'][0]['threadId'], unnamed['id'])
            self.assertEqual(fixed['missingTitleCount'], 0)
            self.assertTrue(fixed['requiresConfirmation'])
        discover.assert_not_called()
        call.assert_not_called()

    def test_title_updates_are_latest_utc_then_last_complete_record(self):
        task_id = str(uuid.uuid4())
        index = self.root / 'session_index.jsonl'
        records = [self.title_record(task_id, '新名称', '2026-09-12T07:00:00Z'),
                   self.title_record(task_id, '较早到达但时间旧', '2026-09-12T14:59:59+08:00'),
                   self.title_record(task_id, '同一时间后写', '2026-09-12T15:00:00+08:00'),
                   self.title_record(task_id, '未提交末行', '2026-09-12T08:00:00Z').rstrip('\n')]
        index.write_text(''.join(records), encoding='utf-8')
        self.assertEqual(bridge.display_title_index(self.root), ({task_id: '同一时间后写'}, True))

    def test_invalid_title_rows_preserve_previous_valid_name(self):
        task_id = str(uuid.uuid4())
        records = [self.title_record(task_id, '有效名称'), '{not-json}\n', '[]\n',
                   self.title_record('not-a-guid', '假任务'), self.title_record(task_id, '  '),
                   self.title_record(task_id, 123), self.title_record(task_id, '坏时间', None),
                   self.title_record(task_id, '坏时间', 'unknown'),
                   self.title_record(task_id, 'UTC越界', '0001-01-01T00:00:00+01:00'),
                   self.title_record(task_id, '无时区', '2026-09-13T07:00:00'), '{}\n',
                   '{"id":']
        (self.root / 'session_index.jsonl').write_text(''.join(records), encoding='utf-8')
        self.assertEqual(bridge.display_title_index(self.root), ({task_id: '有效名称'}, True))

    def test_title_index_cannot_add_excluded_or_unknown_candidates(self):
        with self.index(extra=', host_id TEXT DEFAULT "local", kind TEXT DEFAULT "codex"') as db:
            rows = [self.add_task(db, title='首句')]
            for values in ({'archived': 1}, {'agent_path': '/root/child'},
                           {'host_id': 'remote'}, {'kind': 'chatgpt'}):
                rows.append(self.add_task(db, **values))
            missing = self.add_task(db)
            Path(missing['rollout_path']).unlink()
            rows.append(missing)
        db.close()
        records = [self.title_record(row['id'], '声伴 6.17') for row in rows]
        records.append(self.title_record(str(uuid.uuid4()), '声伴 6.17'))
        (self.root / 'session_index.jsonl').write_text(''.join(records), encoding='utf-8')
        result = bridge.handle({'action': 'find', 'query': '6.17'})
        self.assertEqual(result['matchType'], 'unique')
        self.assertEqual([row['threadId'] for row in result['threads']], [rows[0]['id']])

    def test_missing_or_partial_title_coverage_is_visible_not_hidden(self):
        with self.index() as db:
            covered = self.add_task(db, title='原始名称一')
            fallback = self.add_task(db, title='原始名称二')
        db.close()
        missing = bridge.handle({'action': 'list'})
        self.assertFalse(missing['titleIndexAvailable'])
        self.assertEqual(missing['unsyncedTitleCount'], 2)
        self.assertTrue(missing['warning'])
        (self.root / 'session_index.jsonl').write_text(
            self.title_record(covered['id'], '新名称'), encoding='utf-8')
        partial = bridge.handle({'action': 'list'})
        self.assertTrue(partial['titleIndexAvailable'])
        self.assertEqual(partial['unsyncedTitleCount'], 1)
        self.assertTrue(partial['warning'])
        result = bridge.handle({'action': 'find', 'query': fallback['title']})
        self.assertEqual(result['threads'][0]['titleSource'], 'local_index')
        self.assertTrue(result['warning'])

    def test_unreadable_title_index_does_not_silently_use_stale_names(self):
        with patch.object(Path, 'open', side_effect=PermissionError('busy')):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.display_title_index(self.root)
        self.assertEqual(error.exception.code, 'title_index_unavailable')

    def test_refresh_observes_appended_rename_and_drops_old_title_match(self):
        with self.index() as db:
            row = self.add_task(db)
        db.close()
        index = self.root / 'session_index.jsonl'
        index.write_text(self.title_record(row['id'], '高斯泼溅研究'), encoding='utf-8')
        self.assertEqual(bridge.handle({'action': 'find', 'query': '高斯泼溅'})['matchType'], 'unique')
        with index.open('a', encoding='utf-8') as stream:
            stream.write(self.title_record(row['id'], '声伴 v0.6.17', '2026-09-12T08:00:00Z'))
        self.assertEqual(bridge.handle({'action': 'find', 'query': '高斯泼溅'})['matchType'], 'none')
        self.assertEqual(bridge.handle({'action': 'find', 'query': '6.17'})['matchType'], 'unique')

    def test_find_validates_query_before_index_or_connection(self):
        for query in (None, 123, [], {}, '', '高', '！', 'x' * 201):
            with self.subTest(query=query), patch.object(bridge, 'list_tasks') as listing, \
                    patch.object(bridge, 'discover_pipe') as discover:
                with self.assertRaises(bridge.BridgeError) as error:
                    bridge.handle({'action': 'find', 'query': query})
                self.assertEqual(error.exception.code, 'invalid_query')
                listing.assert_not_called()
                discover.assert_not_called()

    def test_find_ignores_directory_filter_and_propagates_index_error(self):
        with patch.object(bridge, 'list_tasks', side_effect=bridge.BridgeError('index_not_found', 'missing')) as listing:
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.handle({'action': 'find', 'query': '桌面声波', 'cwd': 'invalid-relative-filter'})
        self.assertEqual(error.exception.code, 'index_not_found')
        listing.assert_called_once_with()

    def test_find_reuses_local_candidate_filters(self):
        with self.index(extra=', host_id TEXT DEFAULT "local", kind TEXT DEFAULT "codex"') as db:
            for values in ({'archived': 1}, {'agent_path': '/root/child'},
                           {'host_id': 'remote'}, {'kind': 'chatgpt'}):
                self.add_task(db, title='高斯破渐测试', **values)
        db.close()
        out = bridge.handle({'action': 'find', 'query': '高斯坡建'})
        self.assertEqual((out['matchType'], out['totalMatches']), ('none', 0))
        self.assertEqual(out['threads'], [])

    def test_find_dependency_error_stays_actionable(self):
        with patch.object(bridge, 'list_tasks', return_value={'threads': []}), \
                patch.object(bridge, 'match_tasks', side_effect=bridge.TaskMatchError('phonetic_matching_unavailable', 'missing')):
            with self.assertRaises(bridge.BridgeError) as error:
                bridge.handle({'action': 'find', 'query': '高斯坡建'})
        self.assertEqual(error.exception.code, 'phonetic_matching_unavailable')

    def test_archived_subagent_remote_and_missing_rollouts_are_filtered(self):
        with self.index(extra=', host_id TEXT DEFAULT "local", kind TEXT DEFAULT "codex"') as db:
            expected = self.add_task(db)
            for values in ({'archived': 1}, {'agent_path': '/root/child'},
                           {'source': '{"subagent":{}}'}, {'thread_source': 'subagent'},
                           {'source': 'remote'}, {'host_id': 'remote'}, {'kind': 'chatgpt'},
                           {'cwd': '\\\\wsl.localhost\\Ubuntu\\home\\test'},
                           {'cwd': '\\\\server\\share'}, {'cwd': 'relative'},
                           {'rollout_path': str(self.root / 'missing.jsonl')},
                           {'rollout_path': str(self.root / 'outside.jsonl')}, {'id': 'bad-id'}):
                self.add_task(db, **values)
        db.close()
        out = bridge.handle({'action': 'list'})
        self.assertEqual([row['threadId'] for row in out['threads']], [expected['id']])

    def test_directory_filter_does_not_change_task_cwd(self):
        second_directory = self.root / 'other'
        second_directory.mkdir()
        with self.index() as db:
            self.add_task(db)
            expected = self.add_task(db, cwd=str(second_directory))
        db.close()
        rows = bridge.handle({'action': 'list', 'cwd': str(second_directory)})['threads']
        self.assertEqual([row['threadId'] for row in rows], [expected['id']])
        self.assertEqual(rows[0]['cwd'], str(second_directory))

    def test_wal_recent_commits_are_included_without_modifying_database(self):
        db = self.index()
        self.addCleanup(db.close)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA wal_autocheckpoint=0')
        expected = self.add_task(db)
        self.assertTrue(Path(str(self.root / 'state_5.sqlite') + '-wal').is_file())
        before = db.execute('SELECT * FROM threads').fetchall()
        out = bridge.handle({'action': 'list'})
        self.assertEqual(out['threads'][0]['threadId'], expected['id'])
        self.assertEqual(db.execute('SELECT * FROM threads').fetchall(), before)

    def test_missing_index_has_actionable_error_without_creating_files(self):
        with self.assertRaises(bridge.BridgeError) as error:
            bridge.handle({'action': 'list'})
        self.assertEqual(error.exception.code, 'index_not_found')
        self.assertEqual(list(self.root.glob('state_*.sqlite')), [])

    def test_corrupt_index_has_actionable_error(self):
        (self.root / 'state_5.sqlite').write_bytes(b'not a sqlite database')
        with self.assertRaises(bridge.BridgeError) as error:
            bridge.handle({'action': 'list'})
        self.assertEqual(error.exception.code, 'index_unavailable')

    def test_unknown_newest_schema_does_not_fall_back_to_old_private_state(self):
        with self.index() as db:
            self.add_task(db)
        db.close()
        with sqlite3.connect(self.root / 'state_6.sqlite') as newer:
            newer.execute('CREATE TABLE threads (id TEXT)')
        newer.close()
        with self.assertRaises(bridge.BridgeError) as error:
            bridge.handle({'action': 'list'})
        self.assertEqual(error.exception.code, 'unsupported_index_schema')

    def test_empty_supported_index_is_a_valid_empty_list(self):
        db = self.index()
        db.close()
        self.assertEqual(bridge.handle({'action': 'list'})['threads'], [])


if __name__ == '__main__':
    unittest.main()
