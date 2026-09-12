"""Offline create/status lifecycle checks. All native operations are mocked."""
import concurrent.futures
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

PROJECT_ROOT = Path(__file__).resolve().parents[1]
RUN_ROOT = PROJECT_ROOT / 'work' / 'tests' / 'task-creation'
RUN_ROOT.mkdir(parents=True, exist_ok=True)
sys.dont_write_bytecode = True
sys.path.insert(0, str(PROJECT_ROOT / 'src'))
import codex_bridge as bridge
import task_creation as creation


class CreationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=RUN_ROOT)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.state = self.root / 'state'
        self.source = str(uuid.uuid4())
        self.new_id = str(uuid.uuid4())
        self.request_id = str(uuid.uuid4())
        self.cwd = str(self.root / 'project')
        self.ready = {'threadId': self.new_id, 'hostId': 'local'}
        self.project = {'projectId': 'fixture-project', 'path': self.cwd, 'hostId': 'local',
                        'projectKind': 'local', 'isGitRepository': False}
        self.discover = patch.object(bridge, 'discover_pipe', return_value='fixture-pipe').start()
        self.read = patch.object(bridge, 'read_task', return_value={
            'threadId': self.source, 'hostId': 'local', 'cwd': self.cwd}).start()
        self.addCleanup(patch.stopall)

    def request(self, action='create', **overrides):
        request = {'action': action, 'threadId': self.source, 'requestId': self.request_id,
                   'stateDir': str(self.state)}
        request.update(overrides)
        return bridge.handle(request)

    def row(self):
        with sqlite3.connect(self.state / creation.LEDGER_NAME) as db:
            db.row_factory = sqlite3.Row
            row = db.execute('SELECT * FROM creations WHERE request_id=?', (self.request_id,)).fetchone()
        db.close()
        return row

    def set_row(self, **values):
        with sqlite3.connect(self.state / creation.LEDGER_NAME) as db:
            db.execute('UPDATE creations SET ' + ','.join(key + '=?' for key in values) +
                       ' WHERE request_id=?', (*values.values(), self.request_id))
        db.close()

    def test_projectless_exact_arguments_and_source_preflight(self):
        def create(*args, **kwargs):
            self.read.assert_called_once_with('fixture-pipe', self.source)
            self.assertEqual(self.row()['state'], 'dispatching')
            self.assertEqual(json.loads(self.row()['result'])['targetSnapshot'], {'scope': 'projectless'})
            self.assertEqual(args, ('fixture-pipe', 'create_thread', {
                'prompt': creation.INITIAL_PROMPT, 'target': {'type': 'projectless'}}, self.source))
            self.assertEqual(kwargs, {'request_id': self.request_id, 'mutation': True})
            return self.ready
        with patch.object(bridge, 'app_tool', side_effect=create) as call:
            result = self.request()
        call.assert_called_once()
        self.assertEqual((result['creationState'], result['accepted']), ('ready', True))
        self.assertEqual(result['threadId'], self.new_id)
        self.assertEqual((result['sourceThreadId'], result['requestId']), (self.source, self.request_id))
        self.assertFalse(result['duplicateSuppressed'])

    def test_optional_title_preserved_without_model_or_thinking(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready) as call:
            self.request(title='  中文 " $() ` 标题  ')
        arguments = call.call_args.args[2]
        self.assertEqual(set(arguments), {'target', 'prompt', 'title'})
        self.assertEqual(arguments['title'], '中文 " $() ` 标题')

    def test_duplicate_ready_uses_ledger_without_connection(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready) as call:
            one = self.request()
            self.discover.reset_mock()
            self.read.reset_mock()
            two = self.request()
        self.assertEqual(call.call_count, 1)
        self.discover.assert_not_called()
        self.read.assert_not_called()
        self.assertTrue(two['duplicateSuppressed'])
        self.assertEqual({**one, 'duplicateSuppressed': True}, two)

    def test_unknown_mutation_timeout_is_durable_and_never_replayed(self):
        with patch.object(bridge, 'app_tool', side_effect=bridge.BridgeError('send_unknown', 'timeout', True)) as call:
            one = self.request()
            two = self.request()
            status = self.request('create-status')
        self.assertEqual(call.call_count, 1)
        for result in (one, two, status):
            self.assertEqual((result['creationState'], result['accepted']), ('unknown', None))
        self.assertEqual(self.row()['state'], 'unknown')

    def test_unexpected_exception_after_dispatch_is_unknown(self):
        with patch.object(bridge, 'app_tool', side_effect=ValueError('malformed response')) as call:
            result = self.request()
            self.request()
        self.assertEqual((result['creationState'], result['accepted']), ('unknown', None))
        self.assertEqual(call.call_count, 1)

    def test_preflight_failure_is_rejected_and_not_redispatched(self):
        self.read.side_effect = bridge.BridgeError('wrong_target', 'not local', True)
        with patch.object(bridge, 'app_tool') as call:
            one = self.request()
            two = self.request()
        call.assert_not_called()
        self.assertEqual(self.read.call_count, 1)
        self.assertEqual((one['creationState'], one['accepted']), ('rejected', False))
        self.assertTrue(two['duplicateSuppressed'])

    def test_native_false_after_dispatch_cannot_prove_no_creation(self):
        with patch.object(bridge, 'pipe_request', return_value={'success': False}) as call:
            one = self.request()
            two = self.request()
        self.assertEqual((one['creationState'], one['accepted']), ('unknown', None))
        self.assertEqual(one['errorCode'], 'app_rejected')
        self.assertEqual(call.call_count, 1)
        self.assertTrue(two['duplicateSuppressed'])

    def test_server_created_then_error_is_unknown_and_never_dispatched_again(self):
        server_tasks = []
        def created_then_failed(*args, **kwargs):
            server_tasks.append(self.new_id)
            # The application created a task but failed while preparing its
            # receipt. Generic transport/app errors carry uncertain=False.
            raise bridge.BridgeError('app_rejected', 'fixture receipt serialization failure', False)
        with patch.object(bridge, 'app_tool', side_effect=created_then_failed) as call:
            one = self.request()
            two = self.request()
            status = self.request('create-status')
        self.assertEqual(server_tasks, [self.new_id])
        self.assertEqual(call.call_count, 1)
        for result in (one, two, status):
            self.assertEqual((result['creationState'], result['accepted']), ('unknown', None))
        self.assertTrue(two['duplicateSuppressed'])
        self.assertEqual(self.row()['state'], 'unknown')

    def test_server_created_then_rpc_error_has_the_same_uncertainty_boundary(self):
        server_tasks = []
        def rpc_failed(*args, **kwargs):
            server_tasks.append(self.new_id)
            raise bridge.BridgeError('app_rejected', 'fixture JSON-RPC error after creating', False)
        with patch.object(bridge, 'pipe_request', side_effect=rpc_failed) as pipe:
            one = self.request()
            two = self.request()
        self.assertEqual(server_tasks, [self.new_id])
        self.assertEqual(pipe.call_count, 1)
        self.assertEqual((one['creationState'], one['accepted']), ('unknown', None))
        self.assertTrue(two['duplicateSuppressed'])

    def test_missing_or_nonboolean_success_is_unknown(self):
        for receipt in ({}, {'success': None}, {'success': 'false'}, {'success': 0},
                        {'success': 1}, [], None):
            with self.subTest(receipt=receipt), patch.object(bridge, 'pipe_request', return_value=receipt) as call:
                self.request_id = str(uuid.uuid4())
                one = self.request()
                two = self.request()
                self.assertEqual((one['creationState'], one['accepted']), ('unknown', None))
                self.assertTrue(two['duplicateSuppressed'])
                self.assertEqual(call.call_count, 1)

    def test_unusable_success_receipt_is_unknown(self):
        receipts = [None, [], {}, {'threadId': self.new_id}, {'threadId': self.source, 'hostId': 'local'},
                    {'threadId': self.new_id, 'hostId': 'remote'}, {'threadId': 'bad', 'hostId': 'local'},
                    {'threadId': self.new_id, 'hostId': 'local', 'clientThreadId': 'temporary'},
                    {'threadId': self.new_id, 'hostId': 'local', 'kind': 'chatgpt'},
                    {'clientThreadId': ''}, {'clientThreadId': 'x\n'}, {'clientThreadId': 123},
                    {'clientThreadId': 'x' * 257}, {'clientThreadId': 'x', 'hostId': 'remote'}]
        for receipt in receipts:
            with self.subTest(receipt=receipt), patch.object(bridge, 'app_tool', return_value=receipt) as call:
                self.request_id = str(uuid.uuid4())
                one = self.request()
                two = self.request()
                self.assertEqual((one['creationState'], one['accepted']), ('unknown', None))
                self.assertTrue(two['duplicateSuppressed'])
                self.assertEqual(call.call_count, 1)

    def test_pending_temporary_id_never_passed_to_read_or_wait(self):
        with patch.object(bridge, 'app_tool', return_value={'clientThreadId': 'opaque-not-a-thread'}) as call:
            one = self.request()
            for _ in range(3):
                status = self.request('create-status')
            two = self.request()
        self.assertEqual((one['creationState'], one['accepted']), ('pending', True))
        self.assertNotIn('threadId', one)
        self.assertEqual(one['resolution'], 'manual_check_required')
        self.assertEqual(one, status)
        self.assertTrue(two['duplicateSuppressed'])
        self.assertEqual(call.call_count, 1)
        self.read.assert_called_once_with('fixture-pipe', self.source)

    def test_changed_title_scope_or_source_conflicts_before_preflight(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready) as call:
            self.request()
            for changed in ({'title': 'different'}, {'scope': 'current-project'},
                            {'threadId': str(uuid.uuid4())}):
                with self.subTest(changed=changed), self.assertRaises(bridge.BridgeError) as error:
                    self.request(**changed)
                self.assertEqual(error.exception.code, 'request_id_conflict')
                self.assertTrue(error.exception.uncertain)
        self.assertEqual(call.call_count, 1)
        self.assertEqual(self.read.call_count, 1)

    def test_invalid_inputs_fail_before_storage_or_discovery(self):
        changes = [{'requestId': value} for value in (None, '', 'bad', 4, {})]
        changes += [{'title': value} for value in ('', '  ', 'x' * 121, 'a\nb', 'a\u200bb', 1, [])]
        changes += [{'scope': value} for value in (None, 'other', {}, 1)]
        for changed in changes:
            with self.subTest(changed=changed), self.assertRaises(bridge.BridgeError):
                self.request(**changed)
        self.discover.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_missing_source_and_bad_source_never_dispatch(self):
        for action in ('create', 'create-status'):
            for source in (None, '', 'not-a-thread'):
                with self.subTest(action=action, source=source), self.assertRaises(bridge.BridgeError):
                    self.request(action, threadId=source)
        self.discover.assert_not_called()
        self.assertFalse(self.state.exists())

    def test_status_absent_directory_is_read_only_not_found(self):
        with patch.object(bridge, 'app_tool') as call:
            result = self.request('create-status')
        self.assertEqual((result['creationState'], result['accepted']), ('not_found', False))
        self.assertFalse(self.state.exists())
        self.discover.assert_not_called()
        call.assert_not_called()

    def test_status_absent_row_in_existing_ledger_is_not_found(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready):
            self.request()
        self.discover.reset_mock()
        result = self.request('create-status', requestId=str(uuid.uuid4()))
        self.assertEqual((result['creationState'], result['accepted']), ('not_found', False))
        self.discover.assert_not_called()

    def test_status_wrong_source_cannot_clear_existing_record(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready):
            self.request()
        with self.assertRaises(bridge.BridgeError) as error:
            self.request('create-status', threadId=str(uuid.uuid4()))
        self.assertEqual(error.exception.code, 'creation_source_mismatch')
        self.assertTrue(error.exception.uncertain)

    def test_broken_ledger_and_unknown_schema_never_become_not_found(self):
        self.state.mkdir()
        ledger = self.state / creation.LEDGER_NAME
        ledger.write_bytes(b'not sqlite')
        with self.assertRaises(bridge.BridgeError) as error:
            self.request('create-status')
        self.assertTrue(error.exception.uncertain)
        # This test owns and replaces only its own temporary fixture file.
        ledger.write_bytes(b'')
        with sqlite3.connect(ledger) as db:
            db.execute('CREATE TABLE other (value TEXT)')
        db.close()
        with self.assertRaises(bridge.BridgeError) as error:
            self.request('create-status')
        self.assertEqual(error.exception.code, 'creation_ledger_unavailable')
        self.assertTrue(error.exception.uncertain)

    def test_corrupt_saved_result_is_unknown_and_cannot_replay(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready) as call:
            self.request()
            for value in ('bad-json', 'null', '[]', '{}', json.dumps({
                    'creationState': 'ready', 'accepted': False, 'requestId': self.request_id,
                    'sourceThreadId': self.source, 'threadId': self.new_id, 'hostId': 'local'})):
                with self.subTest(value=value):
                    self.set_row(result=value)
                    result = self.request('create-status')
                    duplicate = self.request()
                    self.assertEqual((result['creationState'], result['accepted']), ('unknown', None))
                    self.assertTrue(duplicate['duplicateSuppressed'])
        self.assertEqual(call.call_count, 1)

    def test_reserved_record_after_crash_is_unknown_without_replay(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready) as call:
            self.request()
            self.set_row(state='dispatching', result=None)
            one = self.request()
            two = self.request('create-status')
        self.assertEqual(call.call_count, 1)
        self.assertEqual((one['creationState'], two['accepted']), ('unknown', None))
        self.assertTrue(one['duplicateSuppressed'])

    def test_concurrent_identical_requests_dispatch_exactly_once(self):
        dispatch_entered, finish_dispatch = threading.Event(), threading.Event()
        def create(*args, **kwargs):
            dispatch_entered.set()
            self.assertTrue(finish_dispatch.wait(5))
            return self.ready
        with patch.object(bridge, 'app_tool', side_effect=create) as call:
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                first = pool.submit(self.request)
                self.assertTrue(dispatch_entered.wait(5))
                try:
                    second = pool.submit(self.request).result(timeout=5)
                    self.assertEqual((second['creationState'], second['accepted']), ('unknown', None))
                    self.assertTrue(second['duplicateSuppressed'])
                finally:
                    finish_dispatch.set()
                self.assertEqual(first.result(timeout=5)['creationState'], 'ready')
        self.assertEqual(call.call_count, 1)

    def test_result_write_failure_preserves_persisted_reservation(self):
        real_connect = sqlite3.connect
        class FailFinalUpdate:
            def __init__(self, *args, **kwargs):
                self.connection = real_connect(*args, **kwargs)
            @property
            def row_factory(self):
                return self.connection.row_factory
            @row_factory.setter
            def row_factory(self, value):
                self.connection.row_factory = value
            def execute(self, statement, *args):
                if statement.startswith('UPDATE creations SET state='):
                    raise sqlite3.OperationalError('fixture disk failure after create')
                return self.connection.execute(statement, *args)
            def __getattr__(self, name):
                return getattr(self.connection, name)
        with patch.object(creation.sqlite3, 'connect', side_effect=FailFinalUpdate), \
                patch.object(bridge, 'app_tool', return_value=self.ready) as call:
            one = self.request()
        self.assertEqual((one['creationState'], one['accepted']), ('unknown', None))
        self.assertEqual(self.row()['state'], 'dispatching')
        with patch.object(bridge, 'app_tool') as retry:
            two = self.request()
        retry.assert_not_called()
        self.assertTrue(two['duplicateSuppressed'])
        self.assertEqual(call.call_count, 1)
        self.assertEqual(two['targetSnapshot'], {'scope': 'projectless'})

    def test_read_only_status_includes_wal_recent_receipt(self):
        with patch.object(bridge, 'app_tool', return_value=self.ready):
            self.request()
        db = sqlite3.connect(self.state / creation.LEDGER_NAME)
        self.addCleanup(db.close)
        db.execute('PRAGMA journal_mode=WAL')
        db.execute('PRAGMA wal_autocheckpoint=0')
        changed = creation.result_for(self.source, self.request_id, 'pending',
                                      clientThreadId='fixture-client', hostId='local')
        db.execute('UPDATE creations SET state=?,result=?', ('pending', json.dumps(changed)))
        db.commit()
        real_connect = sqlite3.connect
        with patch.object(creation.sqlite3, 'connect', wraps=real_connect) as connect:
            status = self.request('create-status')
        self.assertEqual(status['creationState'], 'pending')
        self.assertIn('?mode=ro', connect.call_args.args[0])
        self.assertTrue(connect.call_args.kwargs['uri'])

    def test_current_project_non_git_uses_exact_local_project(self):
        def app(*args, **kwargs):
            if args[1] == 'list_projects':
                self.read.assert_called_once()
                self.assertEqual(args[2], {})
                self.assertEqual(args[3], self.source)
                return {'schemaVersion': 2, 'projects': [self.project]}
            self.assertEqual(args[1], 'create_thread')
            self.assertEqual(args[2], {'prompt': creation.INITIAL_PROMPT, 'target': {
                'type': 'project', 'projectId': 'fixture-project', 'environment': {'type': 'local'}}})
            snapshot = json.loads(self.row()['result'])['targetSnapshot']
            self.assertEqual((snapshot['projectId'], snapshot['environment']), ('fixture-project', 'local'))
            return self.ready
        with patch.object(bridge, 'app_tool', side_effect=app) as call:
            result = self.request(scope='current-project')
        self.assertEqual(call.call_count, 2)
        self.assertEqual(result['creationState'], 'ready')
        self.assertEqual(result['targetSnapshot']['sourceCwd'], self.cwd)

    def test_current_git_project_defaults_to_worktree_and_can_be_pending(self):
        with patch.object(bridge, 'app_tool', side_effect=[
                {'projects': [{**self.project, 'isGitRepository': True}]},
                {'clientThreadId': 'worktree-preparing', 'hostId': 'local'}]) as call:
            result = self.request(scope='current-project', title='项目任务')
        args = call.call_args.args[2]
        self.assertEqual(args['target'], {'type': 'project', 'projectId': 'fixture-project',
                                        'environment': {'type': 'worktree'}})
        self.assertEqual(set(args), {'target', 'prompt', 'title'})
        self.assertEqual(result['creationState'], 'pending')
        self.assertTrue(result['targetSnapshot']['isGitRepository'])

    def test_current_project_normalizes_path_before_exact_comparison(self):
        self.project['path'] = self.cwd + '/./'
        with patch.object(bridge, 'app_tool', side_effect=[{'projects': [self.project]}, self.ready]):
            result = self.request(scope='current-project')
        self.assertEqual(result['creationState'], 'ready')

    def test_project_missing_ambiguous_remote_or_not_exact_never_creates(self):
        cases = [([], 'current_project_not_found'), ([self.project, self.project], 'current_project_ambiguous'),
                 ([{**self.project, 'hostId': 'remote'}], 'current_project_not_found'),
                 ([{**self.project, 'projectKind': 'chatgpt'}], 'current_project_not_found'),
                 ([{**self.project, 'path': str(self.root)}], 'current_project_not_found'),
                 ([{**self.project, 'path': self.cwd + '/child'}], 'current_project_not_found')]
        for projects, code in cases:
            with self.subTest(code=code, projects=projects), \
                    patch.object(bridge, 'app_tool', return_value={'projects': projects}) as call:
                self.request_id = str(uuid.uuid4())
                result = self.request(scope='current-project')
                self.assertEqual((result['creationState'], result['accepted']), ('rejected', False))
                self.assertEqual(result['errorCode'], code)
                call.assert_called_once()
                self.assertEqual(call.call_args.args[1], 'list_projects')

    def test_unknown_project_metadata_rejected_without_creation(self):
        for change in ({'isGitRepository': None}, {'isGitRepository': 'false'}, {'isGitRepository': 0},
                       {'projectId': None}, {'projectId': ''}, {'projectId': 'a\nb'}):
            with self.subTest(change=change), patch.object(bridge, 'app_tool', return_value={
                    'projects': [{**self.project, **change}]}) as call:
                self.request_id = str(uuid.uuid4())
                result = self.request(scope='current-project')
                self.assertEqual((result['creationState'], result['accepted']), ('rejected', False))
                self.assertEqual(result['errorCode'], 'invalid_project_metadata')
                call.assert_called_once()

    def test_invalid_project_catalog_and_missing_cwd_rejected(self):
        for catalog in (None, [], {}, {'projects': {}}, {'projects': None}):
            with self.subTest(catalog=catalog), patch.object(bridge, 'app_tool', return_value=catalog) as call:
                self.request_id = str(uuid.uuid4())
                result = self.request(scope='current-project')
                self.assertEqual(result['errorCode'], 'invalid_projects_response')
                self.assertFalse(result['accepted'])
                call.assert_called_once()
        self.read.return_value = {'cwd': None}
        self.request_id = str(uuid.uuid4())
        with patch.object(bridge, 'app_tool', return_value={'projects': [self.project]}) as call:
            result = self.request(scope='current-project')
        self.assertEqual(result['errorCode'], 'invalid_source_directory')
        self.assertFalse(result['accepted'])
        call.assert_called_once()

    def test_project_catalog_failure_is_preflight_rejection(self):
        with patch.object(bridge, 'app_tool', side_effect=bridge.BridgeError('timeout', 'list failed', True)) as call:
            result = self.request(scope='current-project')
        self.assertEqual((result['creationState'], result['accepted']), ('rejected', False))
        call.assert_called_once()

    def test_duplicate_project_request_does_not_reresolve_moved_project(self):
        with patch.object(bridge, 'app_tool', side_effect=[{'projects': [self.project]}, self.ready]) as call:
            one = self.request(scope='current-project')
            self.read.return_value = {'cwd': str(self.root / 'other')}
            two = self.request(scope='current-project')
        self.assertEqual(call.call_count, 2)
        self.assertEqual(one['targetSnapshot'], two['targetSnapshot'])
        self.assertTrue(two['duplicateSuppressed'])


class RealPreflightTests(unittest.TestCase):
    def test_real_read_validation_precedes_create(self):
        with tempfile.TemporaryDirectory(dir=RUN_ROOT) as state:
            source = str(uuid.uuid4())
            for overrides in ({'id': str(uuid.uuid4())}, {'hostId': 'remote'}, {'kind': 'chatgpt'},
                              {'hostId': None}):
                response = {'thread': {'id': source, 'hostId': 'local', 'kind': 'codex', **overrides}}
                with self.subTest(overrides=overrides), \
                        patch.object(bridge, 'discover_pipe', return_value='fixture-pipe'), \
                        patch.object(bridge, 'app_tool', return_value=response) as call:
                    result = bridge.handle({'action': 'create', 'threadId': source,
                                            'requestId': str(uuid.uuid4()), 'stateDir': state})
                    self.assertEqual((result['creationState'], result['accepted']), ('rejected', False))
                    call.assert_called_once()
                    self.assertEqual(call.call_args.args[1], 'read_thread')


if __name__ == '__main__':
    unittest.main()
