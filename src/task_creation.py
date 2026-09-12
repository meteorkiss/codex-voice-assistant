"""Durable, at-most-once creation of an independent Codex desktop task.

The ledger is the assistant's own SQLite file, never Codex's task database.
Status inspection is read-only and never dispatches or infers a task by title.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import time
import unicodedata
import uuid

LEDGER_NAME = 'create-ledger.sqlite3'
INITIAL_PROMPT = '这是通过声伴新建的语音任务。请等我接下来的具体问题，先简短回复：准备好了，请说。'
MAX_TITLE_LENGTH = 120


def request_uuid(value, error_type):
    if not isinstance(value, str):
        raise error_type('request_id_required', '新建任务请求必须带有稳定 requestId（UUID）。')
    try:
        return str(uuid.UUID(value))
    except (ValueError, AttributeError):
        raise error_type('request_id_required', '新建任务请求必须带有稳定 requestId（UUID）。')


def create_arguments(scope, title, error_type):
    if scope not in ('projectless', 'current-project'):
        raise error_type('unsupported_create_scope', '请选择独立新任务，或在当前项目新建任务。')
    arguments = {'prompt': INITIAL_PROMPT}
    if scope == 'projectless':
        arguments['target'] = {'type': 'projectless'}
    if title is not None:
        if (not isinstance(title, str) or not title.strip() or len(title) > MAX_TITLE_LENGTH or
                any(unicodedata.category(char) in ('Cc', 'Cf', 'Cs') for char in title)):
            raise error_type('invalid_create_title', '任务名称必须是 1 到 120 个字符的单行文字。')
        arguments['title'] = title.strip()
    return arguments


def current_project_target(cwd, catalog, normalize_path, error_type):
    """Use only one exact saved local project, never ancestors or UI recency."""
    source_path = normalize_path(cwd)
    if source_path is None:
        raise error_type('invalid_source_directory', '当前任务没有可核对的本地工作目录，无法在当前项目新建。')
    if not isinstance(catalog, dict) or not isinstance(catalog.get('projects'), list):
        raise error_type('invalid_projects_response', 'Codex 没有返回可核对的项目列表，尚未创建任务。')
    matches = []
    for project in catalog['projects']:
        if (not isinstance(project, dict) or project.get('hostId') != 'local' or
                project.get('projectKind') != 'local'):
            continue
        project_path = normalize_path(project.get('path'))
        if project_path is not None and project_path == source_path:
            matches.append(project)
    if not matches:
        raise error_type('current_project_not_found', '当前任务的目录没有对应的已保存本地项目，尚未创建任务。')
    if len(matches) != 1:
        raise error_type('current_project_ambiguous', '当前目录对应多个项目，无法明确选择，尚未创建任务。')
    project = matches[0]
    project_id = project.get('projectId')
    if (not isinstance(project_id, str) or not project_id or len(project_id) > 256 or
            any(unicodedata.category(char) in ('Cc', 'Cf', 'Cs') for char in project_id) or
            type(project.get('isGitRepository')) is not bool):
        raise error_type('invalid_project_metadata', '当前项目的信息不完整，无法确定创建方式，尚未创建任务。')
    environment = 'worktree' if project['isGitRepository'] else 'local'
    target = {'type': 'project', 'projectId': project_id, 'environment': {'type': environment}}
    snapshot = {'scope': 'current-project', 'sourceCwd': str(source_path), 'projectId': project_id,
                'hostId': 'local', 'isGitRepository': project['isGitRepository'],
                'environment': environment}
    return target, snapshot


def result_for(source, request_id, state, **fields):
    accepted = True if state in ('ready', 'pending') else False if state in ('rejected', 'not_found') else None
    messages = {
        'ready': '独立新任务已创建，正在等待任务校验和绑定。',
        'pending': 'Codex 已接受新建请求，任务仍在准备中；请到 Codex 核对，程序不会再次创建。',
        'unknown': '新建结果尚未确认，请先到 Codex 核对；程序不会自动再次创建。',
        'rejected': '新建请求未执行成功，尚未创建任务。',
        'not_found': '未找到这条新建请求的派发记录。',
    }
    return {'requestId': request_id, 'sourceThreadId': source, 'creationState': state,
            'accepted': accepted, 'duplicateSuppressed': False, 'message': messages[state], **fields}


def normalize_receipt(receipt, source, request_id):
    """Only exact local ready IDs or explicit opaque client IDs are acknowledgments."""
    if not isinstance(receipt, dict) or receipt.get('kind', 'codex') != 'codex':
        return result_for(source, request_id, 'unknown', errorCode='invalid_create_receipt')
    if 'threadId' in receipt:
        try:
            value = receipt['threadId']
            real_id = str(uuid.UUID(value)) if isinstance(value, str) else None
        except (ValueError, AttributeError):
            real_id = None
        if (not real_id or real_id == source or receipt.get('hostId') != 'local' or
                receipt.get('clientThreadId') is not None):
            return result_for(source, request_id, 'unknown', errorCode='invalid_create_receipt')
        return result_for(source, request_id, 'ready', threadId=real_id, hostId='local')
    client_id = receipt.get('clientThreadId')
    if (isinstance(client_id, str) and 0 < len(client_id) <= 256 and client_id == client_id.strip() and
            not any(unicodedata.category(char) in ('Cc', 'Cf', 'Cs') for char in client_id) and
            receipt.get('hostId', 'local') == 'local'):
        # The current public tools expose no verified mapping for this ID.
        # Do not pass it to read_thread/wait_threads or guess by recent titles.
        return result_for(source, request_id, 'pending', clientThreadId=client_id,
                          hostId='local', resolution='manual_check_required')
    return result_for(source, request_id, 'unknown', errorCode='invalid_create_receipt')


def saved_result(row, source, request_id, error_type):
    if row['source_thread'] != source:
        raise error_type('creation_source_mismatch', '这条新建请求属于另一个来源任务，请保留记录并到 Codex 核对。', True)
    if row['state'] == 'dispatching':
        result = result_for(source, request_id, 'unknown', errorCode='dispatch_in_progress_or_interrupted')
        try:
            saved = json.loads(row['result'])
            if isinstance(saved, dict) and isinstance(saved.get('targetSnapshot'), dict):
                result['targetSnapshot'] = saved['targetSnapshot']
        except (ValueError, TypeError):
            pass
        return result
    try:
        result = json.loads(row['result'])
        state = result['creationState']
        expected_accepted = True if state in ('ready', 'pending') else False if state == 'rejected' else None
        if (not isinstance(result, dict) or state not in ('ready', 'pending', 'unknown', 'rejected') or
                state != row['state'] or result.get('requestId') != request_id or
                result.get('sourceThreadId') != source or result.get('accepted') is not expected_accepted):
            raise ValueError('ledger identity or state mismatch')
        if state in ('ready', 'pending'):
            receipt = {key: result[key] for key in ('threadId', 'hostId', 'clientThreadId') if key in result}
            if normalize_receipt(receipt, source, request_id)['creationState'] != state:
                raise ValueError('ledger receipt is not usable')
        return result
    except (ValueError, TypeError, KeyError, AttributeError):
        return result_for(source, request_id, 'unknown', errorCode='invalid_creation_record')


def creation_status(source, request_id, state_dir, error_type):
    """Read only the assistant ledger. Missing records never trigger a create."""
    request_id = request_uuid(request_id, error_type)
    db = None
    try:
        ledger = Path(state_dir).resolve() / LEDGER_NAME
        if not ledger.exists():
            return result_for(source, request_id, 'not_found')
        db = sqlite3.connect(ledger.as_uri() + '?mode=ro', uri=True, timeout=5)
        db.execute('PRAGMA query_only=ON')
        db.row_factory = sqlite3.Row
        row = db.execute('SELECT source_thread,state,result FROM creations WHERE request_id=?',
                         (request_id,)).fetchone()
        return saved_result(row, source, request_id, error_type) if row else result_for(source, request_id, 'not_found')
    except (sqlite3.Error, OSError) as exc:
        raise error_type('creation_ledger_unavailable',
                         '无法只读核对新建记录，请先到 Codex 检查；程序不会再次创建。', True) from exc
    finally:
        if db is not None:
            db.close()


def create_once(source, request_id, scope, title, state_dir, prepare, dispatch, error_type):
    """Reserve durably before live preflight; exactly one caller may dispatch.

    prepare() validates the local source and returns connection, target, snapshot.
    dispatch(connection, arguments, request_id) invokes create_thread once.
    A reserved row after a crash is intentionally uncertain, never replayable.
    """
    request_id = request_uuid(request_id, error_type)
    arguments = create_arguments(scope, title, error_type)
    digest = hashlib.sha256(json.dumps({'source': source, 'scope': scope, 'arguments': arguments}, sort_keys=True,
                                       ensure_ascii=False).encode('utf-8')).hexdigest()
    db = None
    dispatched = False
    snapshot = None
    try:
        root = Path(state_dir).resolve()
        root.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(root / LEDGER_NAME, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute('CREATE TABLE IF NOT EXISTS creations ('
                   'request_id TEXT PRIMARY KEY, source_thread TEXT NOT NULL, digest TEXT NOT NULL, '
                   'state TEXT NOT NULL, result TEXT, created REAL NOT NULL, updated REAL NOT NULL)')
        db.commit()
        db.execute('BEGIN IMMEDIATE')
        prior = db.execute('SELECT * FROM creations WHERE request_id=?', (request_id,)).fetchone()
        if prior:
            db.rollback()
            if prior['digest'] != digest:
                raise error_type('request_id_conflict', '同一 requestId 不能用于不同的新建任务请求。', True)
            return {**saved_result(prior, source, request_id, error_type), 'duplicateSuppressed': True}
        now = time.time()
        db.execute('INSERT INTO creations VALUES (?,?,?,?,?,?,?)',
                   (request_id, source, digest, 'dispatching', None, now, now))
        db.commit()

        try:
            connection, target, snapshot = prepare()
            arguments['target'] = target
            # Save the exact resolved project before creating anything. A later
            # project rename/list change cannot alter a replay (there is none).
            db.execute('UPDATE creations SET result=?,updated=? WHERE request_id=?',
                       (json.dumps({'targetSnapshot': snapshot}, ensure_ascii=False), time.time(), request_id))
            db.commit()
            dispatched = True
            receipt = dispatch(connection, arguments, request_id)
            result = normalize_receipt(receipt, source, request_id)
        except error_type as exc:
            # A generic native error (even success=false or JSON-RPC error)
            # does not prove create_thread had no effect before it failed.
            # Only our own pre-dispatch validation can establish no creation.
            state = 'unknown' if dispatched else 'rejected'
            result = result_for(source, request_id, state, errorCode=exc.code)
            if not dispatched:
                result['message'] = str(exc)
        except Exception:
            result = result_for(source, request_id, 'unknown' if dispatched else 'rejected',
                                errorCode='create_result_unknown' if dispatched else 'create_preflight_failed')
        if snapshot is not None:
            result['targetSnapshot'] = snapshot
        try:
            db.execute('UPDATE creations SET state=?,result=?,updated=? WHERE request_id=?',
                       (result['creationState'], json.dumps(result, ensure_ascii=False), time.time(), request_id))
            db.commit()
        except sqlite3.Error:
            # The earlier committed dispatching row still prevents replay.
            return result_for(source, request_id, 'unknown', errorCode='creation_ledger_update_failed')
        return result
    except (sqlite3.Error, OSError) as exc:
        raise error_type('creation_ledger_unavailable',
                         '无法可靠保存新建记录，请保留本次请求并到 Codex 核对；程序不会自动重试。', True) from exc
    finally:
        if db is not None:
            db.close()
