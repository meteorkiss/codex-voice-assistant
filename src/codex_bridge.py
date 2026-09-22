"""Local bridge to the Codex desktop app's bundled App Tools named pipe.

No HTTP service, API keys, UI automation, app-server spawning, or config changes.
Each invocation accepts one UTF-8 JSON request and atomically writes one result.
Send requires a stable requestId. Never automatically retry an uncertain send.
"""
from __future__ import annotations

import argparse
import concurrent.futures
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import sqlite3
import struct
import sys
import threading
import time
import uuid

from task_matcher import TaskMatchError, match_tasks, validate_query
from task_creation import create_once, creation_status, current_project_target
from desktop_actions import manage_once

PIPE_PREFIX = '\\\\.\\pipe\\'
PIPE_NAME = re.compile(r'codex-browser-use-[0-9a-fA-F-]{36}')
MAX_FRAME = 8 * 1024 * 1024
INDEX_NAME = re.compile(r'state_(\d+)\.sqlite')
INDEX_REQUIRED = {'id', 'title', 'cwd', 'rollout_path', 'archived', 'source', 'updated_at'}
INDEX_OPTIONAL = {'agent_path', 'thread_source', 'parent_thread_id', 'host_id', 'hostId', 'kind'}


class BridgeError(Exception):
    def __init__(self, code, message, uncertain=False):
        super().__init__(message)
        self.code, self.uncertain = code, uncertain


def valid_thread(value):
    if value is None or (isinstance(value, str) and not value.strip()):
        raise BridgeError('thread_required', '尚未绑定任务，请先从任务列表明确选择一个本地 Codex 任务。')
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, AttributeError, TypeError):
        raise BridgeError('invalid_thread', '请选择一个有效的本地 Codex 任务。')


def verify_pipe_owner(stream):
    """Authenticate the open handle, before sending any data (also after discovery).

    Modern desktop builds no longer expose the endpoint in app-server argv.
    A matching pipe name alone is not identity. Require the OS-attested Codex
    package, its foreground executable and our interactive Windows session.
    Do not inspect another process's environment or persist a rotating endpoint.
    """
    import ctypes
    from ctypes import wintypes as w
    import msvcrt
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetNamedPipeServerProcessId.argtypes = [w.HANDLE, ctypes.POINTER(w.ULONG)]
    kernel.OpenProcess.argtypes = [w.DWORD, w.BOOL, w.DWORD]
    kernel.OpenProcess.restype = w.HANDLE
    kernel.CloseHandle.argtypes = [w.HANDLE]
    kernel.GetPackageFamilyName.argtypes = [w.HANDLE, ctypes.POINTER(w.UINT), w.LPWSTR]
    kernel.QueryFullProcessImageNameW.argtypes = [w.HANDLE, w.DWORD, w.LPWSTR, ctypes.POINTER(w.DWORD)]
    kernel.ProcessIdToSessionId.argtypes = [w.DWORD, ctypes.POINTER(w.DWORD)]
    pid = w.ULONG()
    process = None
    try:
        if not kernel.GetNamedPipeServerProcessId(msvcrt.get_osfhandle(stream.fileno()), ctypes.byref(pid)):
            raise OSError('pipe owner unavailable')
        process = kernel.OpenProcess(0x1000, False, pid.value)
        if not process:
            raise OSError('owner process unavailable')
        family = ctypes.create_unicode_buffer(256)
        size = w.UINT(len(family))
        image = ctypes.create_unicode_buffer(32768)
        image_size = w.DWORD(len(image))
        own_session, server_session = w.DWORD(), w.DWORD()
        if (kernel.GetPackageFamilyName(process, ctypes.byref(size), family) != 0
                or family.value != 'OpenAI.Codex_2p2nqsd0c76g0'
                or not kernel.QueryFullProcessImageNameW(process, 0, image, ctypes.byref(image_size))
                or Path(image.value).name.lower() not in ('chatgpt.exe', 'codex.exe')
                or not kernel.ProcessIdToSessionId(os.getpid(), ctypes.byref(own_session))
                or not kernel.ProcessIdToSessionId(pid.value, ctypes.byref(server_session))
                or own_session.value != server_session.value):
            raise OSError('unexpected package, executable or session')
    except OSError as exc:
        raise BridgeError('untrusted_connection', '无法确认连接属于当前 Windows 会话中的 Codex 桌面应用。') from exc
    finally:
        if process:
            kernel.CloseHandle(process)


def pipe_request(path, method, params, timeout=12, mutation=False):
    """Match bundled NativePipeClient: LE uint32 byte length + UTF-8 JSON-RPC.

    A daemon thread enforces a bounded CLI lifetime for synchronous Windows I/O.
    After a timeout the process exits; there is no replay on another pipe.
    """
    if not path.startswith(PIPE_PREFIX) or not PIPE_NAME.fullmatch(path[len(PIPE_PREFIX):]):
        raise BridgeError('invalid_pipe', 'Codex 本地连接地址无效。')
    response_queue = queue.Queue(maxsize=1)
    written = threading.Event()

    def exchange():
        try:
            with open(path, 'r+b', buffering=0) as stream:
                verify_pipe_owner(stream)
                body = json.dumps({'id': 1, 'jsonrpc': '2.0', 'method': method,
                                   'params': params}, ensure_ascii=False).encode('utf-8')
                if len(body) > MAX_FRAME:
                    raise BridgeError('message_too_large', '内容太长，无法发送。')
                # Mark uncertainty before writing any bytes, including partial writes.
                written.set()
                payload = memoryview(struct.pack('<I', len(body)) + body)
                while payload:
                    count = stream.write(payload)
                    if not count:
                        raise OSError('Codex pipe closed during write')
                    payload = payload[count:]

                def exact(size):
                    buf = bytearray()
                    while len(buf) < size:
                        chunk = stream.read(size - len(buf))
                        if not chunk:
                            raise OSError('Codex pipe closed during read')
                        buf.extend(chunk)
                    return bytes(buf)

                size = struct.unpack('<I', exact(4))[0]
                if size > MAX_FRAME:
                    raise OSError('Codex response exceeds maximum frame size')
                response = json.loads(exact(size).decode('utf-8'))
                if response.get('id') != 1:
                    raise OSError('Codex response id mismatch')
                if 'error' in response:
                    raise BridgeError('app_rejected', response['error'].get('message', 'Codex 拒绝了请求。'))
                if 'result' not in response:
                    raise OSError('Codex returned no result')
                response_queue.put(response['result'])
        except BaseException as exc:
            response_queue.put(exc)

    threading.Thread(target=exchange, daemon=True).start()
    try:
        response = response_queue.get(timeout=timeout)
    except queue.Empty:
        raise BridgeError('send_unknown' if mutation and written.is_set() else 'connection_timeout',
                          'Codex 响应超时。若正在发送，请先到 Codex 检查是否收到，程序不会自动重发。',
                          mutation and written.is_set())
    if isinstance(response, BridgeError):
        raise response
    if isinstance(response, BaseException):
        raise BridgeError('send_unknown' if mutation and written.is_set() else 'connection_unavailable',
                          f'Codex 本地连接不可用：{response}', mutation and written.is_set())
    return response


def probe_app_pipe(path):
    result = pipe_request(path, 'tools/list', {'threadStartKind': 'all'}, timeout=2)
    entries = result.get('tools', []) if isinstance(result, dict) else []
    names = {(t.get('namespace'), t.get('name')) for t in entries if isinstance(t, dict)} if isinstance(entries, list) else set()
    if not {('codex_app', x) for x in ['read_thread', 'send_message_to_thread']} <= names:
        raise BridgeError('unsupported_app_version', '当前 Codex 连接不提供所需的任务工具。')
    return path


def discover_pipe(explicit=None):
    """Choose exactly one authenticated App Tools endpoint, never a browser pipe.

    Discovery sends tools/list only. No operation, especially a write, is ever
    replayed on a different endpoint. Discovery is bounded even with dead pipes.
    An explicit endpoint is authoritative; only stale inherited hints fall back.
    """
    if explicit:
        return probe_app_pipe(explicit)
    inherited = os.environ.get('CODEX_APP_TOOLS_PIPE_PATH')
    if inherited:
        try:
            return probe_app_pipe(inherited)
        except BridgeError as exc:
            if exc.code not in ('connection_unavailable', 'connection_timeout'):
                raise
    try:
        candidates = sorted({PIPE_PREFIX + n for n in os.listdir(PIPE_PREFIX) if PIPE_NAME.fullmatch(n)})
    except OSError as exc:
        raise BridgeError('discovery_failed', '无法枚举本机 Codex 连接，请确认 Codex 正在运行。') from exc
    if not candidates:
        raise BridgeError('codex_not_running', '尚未找到 Codex 桌面连接，请先启动 Codex。')
    if len(candidates) > 16:
        raise BridgeError('connection_ambiguous', '候选连接过多，无法安全确定 Codex 桌面连接。')
    found, errors = [], []
    with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
        futures = [pool.submit(probe_app_pipe, path) for path in candidates]
        for future in futures:
            try:
                found.append(future.result())
            except BridgeError as exc:
                errors.append(exc)
    if len(found) > 1:
        raise BridgeError('connection_ambiguous', '找到多个 Codex 任务连接，请关闭多余桌面实例后重试。')
    # A timed-out endpoint may be a second App Tools server: fail closed.
    uncertain = [e for e in errors if e.code not in ('unsupported_app_version', 'untrusted_connection', 'connection_unavailable', 'app_rejected')]
    if uncertain:
        raise uncertain[0]
    if not found:
        raise BridgeError('codex_not_ready', 'Codex 已启动，但任务连接尚未就绪，请稍后重试。')
    return found[0]


def app_tool(pipe, tool, arguments, source_thread, request_id=None, mutation=False):
    request_id = request_id or str(uuid.uuid4())
    result = pipe_request(pipe, 'tools/call', {
        'namespace': 'codex_app', 'tool': tool, 'arguments': arguments,
        'threadId': source_thread, 'turnId': 'mcp-turn-jarvis-' + request_id,
        'callId': 'mcp-call-jarvis-' + request_id,
    }, timeout=45 if mutation else 15, mutation=mutation)
    # Only an explicit boolean false is a definite rejection. A changed or
    # malformed reply after dispatch cannot establish that a send did not happen.
    if not isinstance(result, dict) or type(result.get('success')) is not bool:
        raise BridgeError('send_unknown' if mutation else 'invalid_app_response',
                          'Codex 未返回明确回执。请先到 Codex 核对，程序不会自动重发。', mutation)
    items = result.get('contentItems', [])
    texts = [x['text'] for x in items if isinstance(x, dict) and
             x.get('type') == 'inputText' and isinstance(x.get('text'), str)] if isinstance(items, list) else []
    if result['success'] is False:
        raise BridgeError('app_rejected', '\n'.join(texts) or 'Codex 明确拒绝了请求。')
    if len(texts) == 1:
        try:
            return json.loads(texts[0])
        except json.JSONDecodeError:
            pass
    return {'message': '\n'.join(texts)}


def codex_home():
    return Path(os.environ.get('CODEX_HOME') or Path.home() / '.codex').expanduser().resolve()


def normalized_local_path(value):
    """Reject network/WSL/relative paths; strip Windows long-path decoration."""
    if not isinstance(value, str) or not value.strip():
        return None
    if value.startswith('\\\\?\\'):
        value = value[4:]
    if value.startswith(('\\\\', '//', 'UNC\\')):
        return None
    path = Path(value)
    if not path.is_absolute():
        return None
    return path.resolve()


def local_index_path(root):
    try:
        indexes = [(int(match.group(1)), path) for path in root.glob('state_*.sqlite')
                   if (match := INDEX_NAME.fullmatch(path.name)) and path.is_file()]
    except OSError as exc:
        raise BridgeError('index_unavailable', f'无法读取本机 Codex 任务索引：{exc}')
    if not indexes:
        raise BridgeError('index_not_found', '未找到本机 Codex 任务索引，请先在 Codex 打开一个任务后重新检测。')
    # Never silently fall back to an older database after a schema upgrade.
    return max(indexes, key=lambda item: item[0])[1]


def index_columns(db):
    columns = {row[1] for row in db.execute('PRAGMA table_info(threads)')}
    if not INDEX_REQUIRED <= columns:
        raise BridgeError('unsupported_index_schema',
                          '当前 Codex 任务索引结构不受支持，请更新助手；不会使用旧索引或默认任务。')
    return sorted(INDEX_REQUIRED | (INDEX_OPTIONAL & columns))


def local_main_index_record(item):
    """Use the same metadata-only identity boundary for lookup and binding."""
    return (item['source'] in ('cli', 'vscode', 'exec', 'app-server', 'appServer', 'app_server') and
            not item.get('agent_path') and not item.get('parent_thread_id') and
            item.get('thread_source') not in ('subagent', 'remote', 'cloud', 'chatgpt') and
            item.get('kind', 'codex') == 'codex' and
            item.get('host_id', item.get('hostId', 'local')) == 'local')


def binding_state(thread_id):
    """Read one explicit local task's archive flag, without pipe or transcript.

    Missing means the latest supported index contains no such ID. A moved or
    absent rollout does not establish archival, and unreadable indexes are
    errors rather than a guessed state. mode=ro includes recent WAL commits.
    """
    thread_id = valid_thread(thread_id)
    index = local_index_path(codex_home())
    try:
        with sqlite3.connect(index.as_uri() + '?mode=ro', uri=True, timeout=5) as db:
            db.execute('PRAGMA query_only=ON')
            selected = index_columns(db)
            db.row_factory = sqlite3.Row
            records = db.execute('SELECT ' + ','.join('"' + name + '"' for name in selected) +
                                 ' FROM threads WHERE id=? COLLATE NOCASE LIMIT 2',
                                 (thread_id,)).fetchall()
            if not records:
                return {'threadId': thread_id, 'state': 'missing', 'archived': False}
            if len(records) != 1:
                raise BridgeError('unsupported_index_schema', '本机任务索引含有重复编号，无法确认连接状态。')
            item = dict(records[0])
            if not local_main_index_record(item) or normalized_local_path(item['cwd']) is None:
                raise BridgeError('wrong_target', '目标必须是本机 Codex 主任务。')
            if type(item['archived']) is not int or item['archived'] not in (0, 1):
                raise BridgeError('index_unavailable', '本机任务索引未提供明确的归档状态，暂不允许发送。')
            archived = item['archived'] == 1
            return {'threadId': thread_id, 'state': 'archived' if archived else 'active',
                    'archived': archived}
    except (sqlite3.Error, OSError, ValueError, RuntimeError) as exc:
        raise BridgeError('index_unavailable', f'无法只读确认本机任务状态：{exc}') from exc
    finally:
        if 'db' in locals():
            db.close()


def require_active_binding(thread_id):
    try:
        state = binding_state(thread_id)
    except BridgeError as exc:
        raise BridgeError('task_unavailable', '暂时无法确认目标任务可发送；草稿保留，请重新选择或稍后检测。') from exc
    if state['state'] == 'archived':
        raise BridgeError('task_archived', '目标任务已归档，未发送；请先在 Codex 恢复任务或明确切换到其它对话。')
    if state['state'] != 'active':
        raise BridgeError('task_unavailable', '目标任务已不存在，未发送；请明确选择其它对话。')
    return state


def display_title_index(root):
    """Read Codex's append-only display-name index, without conversation reads.

    SQLite is the identity/path candidate index, not the sidebar rename store.
    A partial trailing write is not a committed rename. Invalid rows cannot
    replace a valid title; equal timestamps use the last complete record.
    """
    path = root / 'session_index.jsonl'
    titles, versions = {}, {}
    try:
        with path.open('r', encoding='utf-8-sig') as stream:
            for line in stream:
                if not line.endswith('\n'):
                    continue
                try:
                    item = json.loads(line)
                    if not isinstance(item, dict):
                        continue
                    task_id = valid_thread(item.get('id'))
                    title = item.get('thread_name')
                    if not isinstance(title, str) or not title.strip():
                        continue
                    updated = datetime.fromisoformat(item['updated_at'].replace('Z', '+00:00'))
                    if updated.tzinfo is None:
                        continue
                    updated = updated.astimezone(timezone.utc)
                except (BridgeError, ValueError, KeyError, TypeError, AttributeError, OverflowError):
                    continue
                if task_id not in versions or updated >= versions[task_id]:
                    versions[task_id], titles[task_id] = updated, title
    except FileNotFoundError:
        return {}, False
    except (OSError, UnicodeError) as exc:
        raise BridgeError('title_index_unavailable',
                          '无法读取 Codex 对话名称索引，请稍后刷新；不会改用过期名称。') from exc
    return titles, True


def list_tasks(cwd=None):
    """Index candidates only: no pipe, fabricated source task, or conversation reads.

    This is an experimental desktop adapter. The selected task must still pass
    read_task's live ID/kind/host checks before binding or sending.
    """
    root = codex_home()
    index = local_index_path(root)
    directory_filter = normalized_local_path(cwd) if cwd is not None else None
    if cwd is not None and directory_filter is None:
        raise BridgeError('invalid_directory_filter', '目录筛选必须是本机的绝对路径。')
    rows = []
    try:
        # mode=ro participates in the current WAL; immutable=1 can return stale rows.
        with sqlite3.connect(index.as_uri() + '?mode=ro', uri=True, timeout=5) as db:
            db.execute('PRAGMA query_only=ON')
            selected = index_columns(db)
            db.row_factory = sqlite3.Row
            cursor = db.execute('SELECT ' + ','.join('"' + name + '"' for name in selected) +
                                ' FROM threads WHERE archived=0 ORDER BY updated_at DESC, id ASC')
            sessions = (root / 'sessions').resolve()
            for record in cursor:
                item = dict(record)
                # Object-valued sources describe spawned agents or an unknown
                # source; only known local session producers are candidates.
                if not local_main_index_record(item):
                    continue
                try:
                    thread_id = valid_thread(item['id'])
                    directory = normalized_local_path(item['cwd'])
                    rollout = normalized_local_path(item['rollout_path'])
                    if directory is None or rollout is None:
                        continue
                    if not rollout.is_relative_to(sessions) or not rollout.is_file():
                        continue
                    if not rollout.name.endswith('-' + thread_id + '.jsonl'):
                        continue
                except (BridgeError, OSError, ValueError, RuntimeError):
                    continue
                if directory_filter is not None and directory != directory_filter:
                    continue
                rows.append({'threadId': thread_id, 'title': item['title'] or '',
                             'cwd': str(directory), 'rolloutPath': str(rollout), 'hostId': 'local',
                             'status': 'unknown', 'requiresValidation': True,
                             'updatedAt': item['updated_at']})
    except sqlite3.Error as exc:
        raise BridgeError('index_unavailable', f'无法只读打开本机 Codex 任务索引，请关闭提示后重新检测：{exc}')
    finally:
        if 'db' in locals():
            db.close()
    # Join on verified candidate IDs only: the name index cannot introduce a
    # remote, archived, missing, or child-agent target on its own.
    titles, title_index_available = display_title_index(root)
    for row in rows:
        task_id = row['threadId']
        row['titleSource'] = 'session_index' if task_id in titles else 'local_index'
        if task_id in titles:
            row['title'] = titles[task_id]
    unsynced = sum(row['titleSource'] != 'session_index' for row in rows)
    missing_titles = sum(not isinstance(row['title'], str) or not row['title'].strip() for row in rows)
    warning = ('部分对话名称尚未同步，暂显示本地记录名；请在 Codex 核对后刷新。' if unsynced else '')
    if missing_titles:
        warning = (f'有 {missing_titles} 个任务的名称为空，无法按名称搜索；请先在 Codex 设置任务名称后刷新。' + warning)
    return {'threads': rows, 'activeThreadDetection': 'explicit_binding',
            'source': 'local_index', 'indexFile': index.name,
            'titleIndexAvailable': title_index_available, 'unsyncedTitleCount': unsynced,
            'missingTitleCount': missing_titles, 'warning': warning,
            'connectionState': 'not_checked', 'requiresValidation': True}


def rollout_path(thread_id):
    codex_dir = codex_home()
    for area in ['sessions', 'archived_sessions']:
        root = codex_dir / area
        if root.is_dir():
            matches = list(root.rglob('*-' + thread_id + '.jsonl'))
            if len(matches) == 1:
                return str(matches[0].resolve())
            if len(matches) > 1:
                return None
    return None


def is_subagent(path):
    if path is None:
        return False
    try:
        with Path(path).open(encoding='utf-8') as stream:
            meta = json.loads(stream.readline(2 * 1024 * 1024)).get('payload', {})
        source = meta.get('source')
        return bool(meta.get('parent_thread_id') or meta.get('agent_path') or
                    (isinstance(source, dict) and 'subagent' in source))
    except (OSError, ValueError):
        return False


def normalized_status(value):
    return value.get('type', 'unknown') if isinstance(value, dict) else str(value or 'unknown')


def read_task(pipe, thread_id):
    thread_id = valid_thread(thread_id)
    result = app_tool(pipe, 'read_thread', {'threadId': thread_id, 'hostId': 'local',
                       'turnLimit': 2, 'includeOutputs': False, 'maxOutputCharsPerItem': 20000}, thread_id)
    thread = result.get('thread', {}) if isinstance(result, dict) else {}
    if not isinstance(thread, dict):
        raise BridgeError('wrong_target', 'Codex 未返回可校验的任务信息，请重新选择任务。')
    if thread.get('id') != thread_id or thread.get('kind') != 'codex' or thread.get('hostId') != 'local':
        raise BridgeError('wrong_target', '目标必须是已存在的本地 Codex 任务。')
    state = binding_state(thread_id)
    if state['state'] == 'missing':
        raise BridgeError('task_unavailable', '本机任务索引中未找到这个任务，请重新选择。')
    path = rollout_path(thread_id)
    if is_subagent(path):
        raise BridgeError('subagent_target', '请选择主任务；子智能体不是语音对话的发送目标。')
    finals = []
    for turn in result.get('turns', []):
        if turn.get('status') != 'completed':
            continue
        for item in reversed(turn.get('items', [])):
            if item.get('type') == 'agentMessage' and item.get('phase') == 'final_answer':
                finals.append({'turnId': turn.get('id'), 'id': item.get('id'), 'text': item.get('text', ''),
                               'truncated': bool(item.get('textTruncated') or item.get('truncated'))})
    return {'threadId': thread_id, 'title': thread.get('title', ''), 'cwd': thread.get('cwd'),
            'hostId': 'local', 'status': normalized_status(thread.get('status')), 'rolloutPath': path,
            'archived': state['archived'], 'bindingState': state['state'],
            'lastAssistantText': finals[0]['text'] if finals else '',
            'lastAssistantTextTruncated': finals[0]['truncated'] if finals else False,
            'finalMessages': finals, 'activeThreadDetection': 'explicit_binding'}


def send_identity(thread_id, text, request_id):
    thread_id = valid_thread(thread_id)
    if not isinstance(text, str) or not text.strip():
        raise BridgeError('empty_message', '没有可以发送的文字。')
    try:
        request_id = str(uuid.UUID(str(request_id)))
    except (ValueError, AttributeError, TypeError):
        raise BridgeError('request_id_required', '发送请求必须带有唯一 requestId（UUID）。')
    digest = hashlib.sha256((thread_id + '\0' + text).encode('utf-8')).hexdigest()
    return thread_id, request_id, digest


def prior_send_result(prior, digest):
    if prior[0] != digest:
        raise BridgeError('request_id_conflict', '同一 requestId 不能用于不同内容。')
    if prior[1] == 'accepted':
        return {**json.loads(prior[2]), 'duplicateSuppressed': True}
    raise BridgeError('duplicate_suppressed', '这条发送请求已经处理或结果未确认，已阻止重复发送。请先检查 Codex。',
                      prior[1] in ['pending', 'unknown'])


def existing_send_result(thread_id, text, request_id, state_dir):
    """Preserve a stored unknown outcome before new target-state rejections.

    This read-only preflight never creates a ledger or replays a request. The
    transactional guard in send_once still handles concurrent/new submissions.
    """
    thread_id, request_id, digest = send_identity(thread_id, text, request_id)
    path = Path(state_dir).resolve() / 'send-ledger.sqlite3'
    try:
        if not path.is_file():
            return None
        with sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=5) as db:
            db.execute('PRAGMA query_only=ON')
            prior = db.execute('SELECT digest,state,result FROM sends WHERE request_id=?',
                               (request_id,)).fetchone()
            return prior_send_result(prior, digest) if prior else None
    except (sqlite3.Error, OSError, ValueError) as exc:
        raise BridgeError('send_ledger_unavailable', '无法确认已有发送记录，请先核对 Codex；不会重复发送。', True) from exc
    finally:
        if 'db' in locals():
            db.close()


def send_once(pipe, thread_id, text, request_id, state_dir):
    thread_id, request_id, digest = send_identity(thread_id, text, request_id)
    state_dir = Path(state_dir).resolve()
    state_dir.mkdir(parents=True, exist_ok=True)
    db = sqlite3.connect(state_dir / 'send-ledger.sqlite3', timeout=5)
    db.execute('CREATE TABLE IF NOT EXISTS sends (request_id TEXT PRIMARY KEY, digest TEXT NOT NULL, state TEXT NOT NULL, result TEXT, created REAL NOT NULL)')
    db.commit()
    db.execute('BEGIN IMMEDIATE')
    prior = db.execute('SELECT digest,state,result FROM sends WHERE request_id=?', (request_id,)).fetchone()
    if prior:
        db.rollback(); db.close()
        return prior_send_result(prior, digest)
    db.execute('INSERT INTO sends VALUES (?,?,?,?,?)', (request_id, digest, 'pending', None, time.time()))
    db.commit()
    try:
        # The ledger may have waited for another writer after handle's check.
        # Validate again at the actual dispatch boundary; an old ledger result
        # was already handled above and cannot be relabeled or replayed here.
        require_active_binding(thread_id)
        result = app_tool(pipe, 'send_message_to_thread',
                          {'threadId': thread_id, 'hostId': 'local', 'prompt': text},
                          thread_id, request_id=request_id, mutation=True)
        if (not isinstance(result, dict) or result.get('threadId') != thread_id or
                result.get('hostId', 'local') != 'local'):
            raise BridgeError('send_unknown', 'Codex 的回执目标不一致，请到 Codex 检查，程序不会重发。', True)
        output = {'threadId': thread_id, 'requestId': request_id, 'accepted': True,
                  'modelOverride': False, 'duplicateSuppressed': False,
                  'message': 'Codex 已接收。空闲时开始回答，处理中则补充到当前任务。'}
        db.execute('UPDATE sends SET state=?,result=? WHERE request_id=?',
                   ('accepted', json.dumps(output, ensure_ascii=False), request_id)); db.commit()
        return output
    except BridgeError as exc:
        try:
            db.execute('UPDATE sends SET state=? WHERE request_id=?',
                       ('unknown' if exc.uncertain else 'rejected', request_id)); db.commit()
        except sqlite3.Error:
            # The pre-dispatch pending row still protects this request after a
            # restart. Do not tell the UI it may clear its uncertainty lock.
            raise BridgeError('send_unknown', '发送记录未能更新，请先到 Codex 核对，程序不会重发。', True) from exc
        raise
    except Exception as exc:
        try:
            db.execute('UPDATE sends SET state=? WHERE request_id=?', ('unknown', request_id)); db.commit()
        except sqlite3.Error:
            pass  # The persisted pending record also suppresses retries.
        raise BridgeError('send_unknown', f'发送结果未确认，请先在 Codex 检查：{exc}', True)
    finally:
        db.close()


def handle(request):
    if not isinstance(request, dict):
        raise BridgeError('invalid_request', '请求必须是 JSON 对象。')
    action = request.get('action')
    if action not in ['read', 'list', 'find', 'binding-state', 'send', 'open', 'create', 'create-status', 'manage']:
        raise BridgeError('invalid_action', 'action 必须为 read、list、find、binding-state、send、open、create、create-status 或 manage。')
    if action == 'list':
        return list_tasks(request.get('cwd'))
    if action == 'find':
        try:
            # Validate before any index access. Searching titles is independent
            # of the current binding, UI directory filter, and running pipe.
            validate_query(request.get('query'))
            listing = list_tasks()
            result = match_tasks(request['query'], listing['threads'])
            result['warning'] = listing.get('warning', '')
            result['missingTitleCount'] = listing.get('missingTitleCount', 0)
            # Incomplete names can hide another same-version candidate. A
            # unique visible match is not sufficient for automatic binding.
            if result['missingTitleCount'] and result['matchType'] == 'unique':
                result['requiresConfirmation'] = True
            return result
        except TaskMatchError as exc:
            raise BridgeError(exc.code, str(exc)) from exc
    thread_id = valid_thread(request.get('threadId'))
    if action == 'binding-state':
        return binding_state(thread_id)
    if action == 'manage':
        return manage_once(thread_id, request.get('requestId'), request.get('command'),
                           request.get('stateDir') or Path(__file__).resolve().parents[1] / 'data',
                           lambda: discover_pipe(request.get('pipePath')), app_tool, read_task,
                           lambda pipe: pipe_request(pipe, 'tools/list', {'threadStartKind': 'all'}, timeout=6),
                           BridgeError, local_candidates=list_tasks)
    if action in ('create', 'create-status'):
        state_dir = request.get('stateDir') or Path(__file__).resolve().parents[1] / 'data'
        if action == 'create-status':
            return creation_status(thread_id, request.get('requestId'), state_dir, BridgeError)

        def prepare_creation():
            connection = discover_pipe(request.get('pipePath'))
            source = read_task(connection, thread_id)
            if request.get('scope', 'projectless') == 'current-project':
                catalog = app_tool(connection, 'list_projects', {}, thread_id)
                target, snapshot = current_project_target(source.get('cwd'), catalog,
                                                           normalized_local_path, BridgeError)
            else:
                target, snapshot = {'type': 'projectless'}, {'scope': 'projectless'}
            return connection, target, snapshot

        def dispatch_creation(connection, arguments, request_id):
            return app_tool(connection, 'create_thread', arguments, thread_id,
                            request_id=request_id, mutation=True)

        return create_once(thread_id, request.get('requestId'), request.get('scope', 'projectless'),
                           request.get('title'), state_dir, prepare_creation, dispatch_creation, BridgeError)
    state_dir = request.get('stateDir') or Path(__file__).resolve().parents[1] / 'data'
    if action == 'send':
        prior = existing_send_result(thread_id, request.get('text'), request.get('requestId'), state_dir)
        if prior is not None:
            return prior
        require_active_binding(thread_id)
    pipe = discover_pipe(request.get('pipePath'))
    if action == 'read':
        return read_task(pipe, thread_id)
    # Verify exact local destination before the first mutation. No model/permission overrides.
    read_task(pipe, thread_id)
    if action == 'open':
        result = app_tool(pipe, 'navigate_to_codex_page', {'threadId': thread_id}, thread_id)
        return {'threadId': thread_id, 'opened': True, 'result': result}
    # Recheck after the live read, immediately before dispatch. Reading an
    # archived task is permitted for recovery, but sending must never restore it.
    require_active_binding(thread_id)
    return send_once(pipe, thread_id, request.get('text'), request.get('requestId'),
                     state_dir)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    try:
        request = json.loads(args.request.read_text(encoding='utf-8-sig'))
        result = {'ok': True, **handle(request)}
    except BridgeError as exc:
        result = {'ok': False, 'error': {'code': exc.code, 'message': str(exc), 'uncertain': exc.uncertain},
                  'retrySafe': False}
    except Exception as exc:
        result = {'ok': False, 'error': {'code': 'bridge_error', 'message': str(exc), 'uncertain': False},
                  'retrySafe': False}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_name(args.output.name + '.' + uuid.uuid4().hex + '.tmp')
    temporary.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
    os.replace(temporary, args.output)
    if sys.stdout is not None:
        try:
            sys.stdout.reconfigure(encoding='utf-8', errors='replace')
            print(json.dumps({'ok': result['ok'], 'output': str(args.output.resolve())}, ensure_ascii=False))
        except (OSError, AttributeError):
            pass
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
