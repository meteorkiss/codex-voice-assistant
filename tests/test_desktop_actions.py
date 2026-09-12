"""Behavioral offline tests for literal desktop commands; no real mutation."""
import concurrent.futures
import copy
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
import uuid

ROOT = Path(__file__).resolve().parents[1]
RUN_ROOT = ROOT / 'work' / 'tests' / 'desktop-actions'
RUN_ROOT.mkdir(parents=True, exist_ok=True)
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'src'))
import codex_bridge as bridge
import desktop_actions as actions

SOURCE = str(uuid.uuid4())
OTHER = str(uuid.uuid4())


class FakeDesktop:
    def __init__(self):
        self.calls = []
        self.threads = {SOURCE: self.info(SOURCE, '当前任务', 'active'),
                        OTHER: self.info(OTHER, '工作任务', 'idle')}
        self.sections = [{'sectionId': x, 'name': x, 'itemKeys': []} for x in ('pinned', 'threads', 'chats')]
        self.sections += [{'sectionId': 'section-work', 'name': '工作', 'itemKeys': []},
                          {'sectionId': 'section-todo', 'name': '待办', 'itemKeys': []}]
        self.archived_ids = set()
        self.extra_rows = []
        self.available = {'read_thread', 'list_threads', 'list_projects', 'list_archived_threads',
                          'create_sidebar_section', 'rename_sidebar_section', 'delete_sidebar_section',
                          'reorder_sidebar_sections', 'set_thread_title', 'set_thread_archived',
                          'move_thread_to_sidebar_section', 'navigate_to_codex_page'}

    @staticmethod
    def info(tid, title, status):
        return {'threadId': tid, 'title': title, 'hostId': 'local', 'status': status,
                'lastAssistantText': '真实的最后回答。', 'lastAssistantTextTruncated': False}

    def tools(self, pipe):
        return {'tools': [{'namespace': 'codex_app', 'name': x} for x in self.available]}

    def read(self, pipe, tid):
        return copy.deepcopy(self.threads[tid])

    def rows(self, archived=False):
        return [{'id': tid, 'title': t['title'], 'kind': 'codex', 'hostId': 'local'}
                for tid, t in self.threads.items() if (tid in self.archived_ids) == archived]

    def call(self, pipe, tool, args, source, request_id=None, mutation=False):
        self.calls.append((tool, copy.deepcopy(args), source, mutation))
        if tool == 'list_threads':
            return {'threads': self.rows() + copy.deepcopy(self.extra_rows), 'pinnedThreads': [],
                    'sections': copy.deepcopy(self.sections), 'unavailableHosts': []}
        if tool == 'list_archived_threads':
            return {'threads': self.rows(True), 'nextCursor': None}
        if tool == 'list_projects':
            return {'projects': [{'projectId': 'project-voice', 'label': '语音助手', 'hostId': 'local', 'projectKind': 'local'},
                                 {'projectId': 'remote', 'label': '远程项目', 'hostId': 'remote', 'projectKind': 'remote'}]}
        if tool == 'create_sidebar_section':
            self.sections.append({'sectionId': 'new-' + args['name'], 'name': args['name'], 'itemKeys': []})
        elif tool == 'rename_sidebar_section':
            next(s for s in self.sections if s['sectionId'] == args['sectionId'])['name'] = args['name']
        elif tool == 'delete_sidebar_section':
            self.sections = [s for s in self.sections if s['sectionId'] != args['sectionId']]
        elif tool == 'reorder_sidebar_sections':
            custom = {s['sectionId']: s for s in self.sections if s['sectionId'] not in actions.BUILTIN_SECTIONS}
            self.sections = [s for s in self.sections if s['sectionId'] in actions.BUILTIN_SECTIONS] + [custom[x] for x in args['sectionIds']]
        elif tool == 'set_thread_title':
            self.threads[args['threadId']]['title'] = args['title']
        elif tool == 'set_thread_archived':
            (self.archived_ids.add if args['archived'] else self.archived_ids.discard)(args['threadId'])
        elif tool == 'move_thread_to_sidebar_section':
            key = 'codex:thread:local:' + args['threadId']
            for section in self.sections:
                section['itemKeys'] = [x for x in section['itemKeys'] if x != key]
                if section['sectionId'] == (args['sectionId'] or 'chats'):
                    section['itemKeys'].append(key)
        elif tool == 'navigate_to_codex_page':
            return {'navigated': True}
        else:
            raise AssertionError('Unexpected tool ' + tool)
        return {}

    def mutations(self):
        return [c for c in self.calls if c[-1]]


class ManagementTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=RUN_ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.desktop = FakeDesktop()
        self.request_id = str(uuid.uuid4())
        self.local_candidates = None

    def run_command(self, operation, request_id=None, **fields):
        return actions.manage_once(SOURCE, request_id or self.request_id, {'operation': operation, **fields},
                                   self.tmp.name, lambda: 'fake', self.desktop.call,
                                   self.desktop.read, self.desktop.tools, bridge.BridgeError,
                                   local_candidates=self.local_candidates)

    def test_creation_is_verified_and_duplicate_has_no_tool_calls(self):
        first = self.run_command('create_section', name='周末')
        count = len(self.desktop.calls)
        replay = self.run_command('create_section', name='周末')
        self.assertEqual(first['operation'], 'create_section')
        self.assertEqual(first['requestId'], self.request_id)
        self.assertEqual(first['sectionId'], 'new-周末')
        self.assertTrue(replay['duplicateSuppressed'])
        self.assertEqual(len(self.desktop.calls), count)
        self.assertEqual(len(self.desktop.mutations()), 1)
        self.assertEqual(self.desktop.mutations()[0][2], SOURCE)

    def test_create_same_name_different_request_ids_is_idempotent(self):
        self.run_command('create_section', name='周末')
        out = self.run_command('create_section', name='周末', request_id=str(uuid.uuid4()))
        self.assertTrue(out['alreadyExists'])
        self.assertEqual(len(self.desktop.mutations()), 1)

    def test_concurrent_same_name_creates_once(self):
        def invoke(_):
            return self.run_command('create_section', name='周末', request_id=str(uuid.uuid4()))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(invoke, range(2)))
        self.assertEqual(len(self.desktop.mutations()), 1)
        self.assertEqual(sum(bool(x.get('alreadyExists')) for x in results), 1)

    def test_section_rename_and_move_use_catalog_ids(self):
        self.run_command('rename_section', section='待办', newName='周末')
        out = self.run_command('move_thread', target='current', section='周末', request_id=str(uuid.uuid4()))
        calls = self.desktop.mutations()
        self.assertEqual(calls[0][1], {'sectionId': 'section-todo', 'name': '周末'})
        self.assertEqual(calls[1][1], {'threadId': SOURCE, 'hostId': 'local', 'sectionId': 'section-todo'})
        self.assertEqual(out['targetThreadId'], SOURCE)

    def test_source_active_does_not_block_rename_pin_sections(self):
        self.run_command('rename_thread', target='current', name='新的任务')
        self.run_command('pin_thread', target='current', request_id=str(uuid.uuid4()))
        self.run_command('create_section', name='周末', request_id=str(uuid.uuid4()))
        self.assertEqual(len(self.desktop.mutations()), 3)

    def test_busy_other_and_current_cannot_archive(self):
        for target, status in [('current', 'active'), ('工作任务', 'active'), ('工作任务', 'unknown')]:
            with self.subTest(target=target, status=status):
                self.desktop.threads[OTHER]['status'] = status
                with self.assertRaises(bridge.BridgeError):
                    self.run_command('archive_thread', target=target, request_id=str(uuid.uuid4()))
        self.assertEqual(self.desktop.mutations(), [])

    def test_archive_and_restore_exact_named_other(self):
        self.run_command('archive_thread', target='工作任务')
        self.assertIn(OTHER, self.desktop.archived_ids)
        out = self.run_command('restore_thread', target='工作任务', request_id=str(uuid.uuid4()))
        self.assertNotIn(OTHER, self.desktop.archived_ids)
        self.assertEqual(out['targetThreadId'], OTHER)

    def test_duplicate_titles_refused_and_remote_is_not_selected(self):
        other_id = str(uuid.uuid4())
        self.desktop.threads[other_id] = self.desktop.info(other_id, '工作任务', 'idle')
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('pin_thread', target='工作任务')
        self.assertEqual(exc.exception.code, 'ambiguous_thread')
        self.desktop.extra_rows = [{'id': str(uuid.uuid4()), 'title': '远程', 'kind': 'codex', 'hostId': 'remote'},
                                   {'id': str(uuid.uuid4()), 'title': 'ChatGPT', 'kind': 'chatgpt', 'hostId': 'local'}]
        for target in ('远程', 'ChatGPT', '工作'):
            with self.assertRaises(bridge.BridgeError) as exc:
                self.run_command('pin_thread', target=target, request_id=str(uuid.uuid4()))
            self.assertEqual(exc.exception.code, 'thread_not_found')
        self.assertEqual(self.desktop.mutations(), [])

    def test_incomplete_catalog_refuses_named_mutation(self):
        self.desktop.extra_rows = [{'id': str(uuid.uuid4()), 'title': str(n), 'kind': 'codex', 'hostId': 'local'} for n in range(48)]
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('pin_thread', target='工作任务')
        self.assertEqual(exc.exception.code, 'incomplete_thread_catalog')
        self.assertEqual(self.desktop.mutations(), [])

    def test_project_task_missing_from_catalog_uses_validated_index_candidate(self):
        self.local_candidates = lambda: {'threads': [{'threadId': OTHER, 'title': '', 'hostId': 'local'}]}
        original_rows = self.desktop.rows
        self.desktop.rows = lambda archived=False: [r for r in original_rows(archived) if r['id'] != OTHER]
        out = self.run_command('rename_thread', target='工作任务', name='新项目任务')
        self.assertEqual(out['targetThreadId'], OTHER)
        self.assertEqual(self.desktop.threads[OTHER]['title'], '新项目任务')

    def test_catalog_omission_cannot_hide_duplicate_title(self):
        hidden = str(uuid.uuid4())
        self.desktop.threads[hidden] = self.desktop.info(hidden, '工作任务', 'idle')
        self.local_candidates = lambda: {'threads': [{'threadId': hidden, 'title': '', 'hostId': 'local'}]}
        original_rows = self.desktop.rows
        self.desktop.rows = lambda archived=False: [r for r in original_rows(archived) if r['id'] != hidden]
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('pin_thread', target='工作任务')
        self.assertEqual(exc.exception.code, 'ambiguous_thread')
        self.assertEqual(self.desktop.mutations(), [])

    def test_unknown_section_and_project_name_do_not_create_or_move(self):
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('move_thread', target='current', section='语音助手')
        self.assertEqual(exc.exception.code, 'section_not_found')
        self.assertEqual(self.desktop.mutations(), [])

    def test_missing_tool_and_builtin_sections_are_rejected_before_dispatch(self):
        self.desktop.available.remove('create_sidebar_section')
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('create_section', name='周末')
        self.assertEqual(exc.exception.code, 'unsupported_app_version')
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('delete_section', section='pinned', request_id=str(uuid.uuid4()))
        self.assertEqual(exc.exception.code, 'builtin_section')
        self.assertEqual(self.desktop.mutations(), [])

    def test_section_to_top_preserves_every_custom_id(self):
        self.run_command('section_to_top', section='待办')
        self.assertEqual(self.desktop.mutations()[0][1], {'sectionIds': ['section-todo', 'section-work']})
        self.assertEqual(len(self.desktop.sections), 5)

    def test_delete_section_only_calls_section_delete(self):
        out = self.run_command('delete_section', section='待办')
        self.assertIn('仍保留', out['message'])
        self.assertEqual([c[0] for c in self.desktop.mutations()], ['delete_sidebar_section'])

    def test_unpin_does_not_remove_task_from_custom_section(self):
        key = 'codex:thread:local:' + SOURCE
        self.desktop.sections[-1]['itemKeys'] = [key]
        out = self.run_command('unpin_thread', target='current')
        self.assertTrue(out['alreadyUnpinned'])
        self.assertEqual(self.desktop.sections[-1]['itemKeys'], [key])
        self.assertEqual(self.desktop.mutations(), [])

    def test_pin_then_unpin(self):
        self.run_command('pin_thread', target='current')
        self.run_command('unpin_thread', target='current', request_id=str(uuid.uuid4()))
        self.assertIsNone(self.desktop.mutations()[-1][1]['sectionId'])

    def test_real_answer_only_and_status_never_invents_completion(self):
        answer = self.run_command('read_thread', target='current')
        self.assertEqual(answer['text'], '真实的最后回答。')
        status = self.run_command('status_thread', target='current', request_id=str(uuid.uuid4()))
        self.assertEqual(status['status'], 'active')
        self.assertNotIn('完成', status['message'])
        for truncated, text in [(True, '被截断'), (False, '')]:
            self.desktop.threads[SOURCE].update(lastAssistantText=text, lastAssistantTextTruncated=truncated)
            out = self.run_command('read_thread', target='current', request_id=str(uuid.uuid4()))
            self.assertNotIn('text', out)

    def test_list_outputs_filter_remote_and_builtin(self):
        sections = self.run_command('list_sections')['sections']
        projects = self.run_command('list_projects', request_id=str(uuid.uuid4()))['projects']
        self.assertEqual([s['name'] for s in sections], ['工作', '待办'])
        self.assertEqual(projects, [{'projectId': 'project-voice', 'name': '语音助手'}])

    def test_navigate_requires_real_receipt(self):
        out = self.run_command('open_thread', target='工作任务')
        self.assertEqual(out['targetThreadId'], OTHER)

    def test_uncertain_mutation_and_failed_verification_never_replay(self):
        original = self.desktop.call
        def rejected(pipe, tool, args, source, **kwargs):
            if tool == 'create_sidebar_section':
                raise bridge.BridgeError('app_rejected', 'adapter failure')
            return original(pipe, tool, args, source, **kwargs)
        with patch.object(self.desktop, 'call', side_effect=rejected) as call:
            with self.assertRaises(bridge.BridgeError) as first:
                self.run_command('create_section', name='周末')
            self.assertTrue(first.exception.uncertain)
            count = call.call_count
            with self.assertRaises(bridge.BridgeError) as second:
                self.run_command('create_section', name='周末')
            self.assertTrue(second.exception.uncertain)
            self.assertEqual(call.call_count, count)
        def ignored(pipe, tool, args, source, **kwargs):
            if tool == 'create_sidebar_section':
                return {}
            return original(pipe, tool, args, source, **kwargs)
        with patch.object(self.desktop, 'call', side_effect=ignored):
            with self.assertRaises(bridge.BridgeError) as exc:
                self.run_command('create_section', name='其他', request_id=str(uuid.uuid4()))
            self.assertTrue(exc.exception.uncertain)

    def test_request_conflict_and_pending_restart_have_no_calls(self):
        self.run_command('create_section', name='周末')
        before = len(self.desktop.calls)
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('create_section', name='周六')
        self.assertEqual(exc.exception.code, 'request_id_conflict')
        with sqlite3.connect(Path(self.tmp.name) / actions.LEDGER_NAME) as db:
            db.execute('UPDATE actions SET state="pending"')
        db.close()
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('create_section', name='周末')
        self.assertTrue(exc.exception.uncertain)
        self.assertEqual(len(self.desktop.calls), before)

    def test_unvalidated_source_target_and_malformed_commands_never_dispatch(self):
        self.desktop.threads[SOURCE]['hostId'] = 'remote'
        with self.assertRaises(bridge.BridgeError) as exc:
            self.run_command('create_section', name='周末')
        self.assertEqual(exc.exception.code, 'wrong_target')
        self.assertEqual(self.desktop.calls, [])
        with self.assertRaises(bridge.BridgeError):
            self.run_command('move_thread', target='current', section='待办', prompt='do something')

    def test_ledger_update_failure_leaves_pending_and_blocks_retry(self):
        real_connect = sqlite3.connect
        class FailingUpdate:
            def __init__(self, *args, **kwargs):
                object.__setattr__(self, 'connection', real_connect(*args, **kwargs))
            def execute(self, sql, *args):
                if sql.startswith('UPDATE actions'):
                    raise sqlite3.OperationalError('simulated disk failure')
                return self.connection.execute(sql, *args)
            def __getattr__(self, name):
                return getattr(self.connection, name)
            def __setattr__(self, name, value):
                setattr(self.connection, name, value)
        with patch.object(actions.sqlite3, 'connect', side_effect=FailingUpdate):
            with self.assertRaises(bridge.BridgeError) as first:
                self.run_command('create_section', name='周末')
        self.assertTrue(first.exception.uncertain)
        before = len(self.desktop.calls)
        with self.assertRaises(bridge.BridgeError) as second:
            self.run_command('create_section', name='周末')
        self.assertTrue(second.exception.uncertain)
        self.assertEqual(len(self.desktop.calls), before)
        self.assertEqual(len(self.desktop.mutations()), 1)


class BridgeIntegrationTests(unittest.TestCase):
    def test_manage_is_routed_without_send_fallback(self):
        with patch.object(bridge, 'manage_once', return_value={'message': 'test'}) as manage, \
                patch.object(bridge, 'send_once') as send:
            self.assertEqual(bridge.handle({'action': 'manage', 'threadId': SOURCE,
                                           'requestId': str(uuid.uuid4()), 'command': {'operation': 'list_sections'}}),
                             {'message': 'test'})
        manage.assert_called_once()
        send.assert_not_called()

    def test_missing_source_rejected_before_connection(self):
        with patch.object(bridge, 'discover_pipe') as discover:
            with self.assertRaises(bridge.BridgeError) as exc:
                bridge.handle({'action': 'manage', 'command': {'operation': 'list_sections'}})
        self.assertEqual(exc.exception.code, 'thread_required')
        discover.assert_not_called()


if __name__ == '__main__':
    unittest.main()
