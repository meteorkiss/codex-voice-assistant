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


class SendTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=RUN_ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.request_id = str(uuid.uuid4())

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


class ReadTests(unittest.TestCase):
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
        for action in ('read', 'send', 'open', 'create', 'create-status', 'manage'):
            for value in (None, '', '  '):
                with self.subTest(action=action, value=value), patch.object(bridge, 'discover_pipe') as call:
                    request = {'action': action}
                    if value is not None:
                        request['threadId'] = value
                    with self.assertRaises(bridge.BridgeError) as error:
                        bridge.handle(request)
                    self.assertEqual(error.exception.code, 'thread_required')
                    call.assert_not_called()

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
