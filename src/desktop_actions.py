"""Literal local desktop commands, with durable at-most-once dispatch.

Only App Tools are called. Catalog labels are data, never prompts. This module
does not modify Codex's private database or forward failed commands to a model.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import sqlite3
import time
import unicodedata
import uuid

LEDGER_NAME = 'desktop-actions.sqlite3'
BUILTIN_SECTIONS = {'pinned', 'threads', 'chats'}
FIELDS = {
    'create_section': {'name'}, 'rename_section': {'section', 'newName'},
    'delete_section': {'section'}, 'section_to_top': {'section'},
    'move_thread': {'target', 'section'}, 'rename_thread': {'target', 'name'},
    'pin_thread': {'target'}, 'unpin_thread': {'target'},
    'archive_thread': {'target'}, 'restore_thread': {'target'},
    'open_thread': {'target'}, 'status_thread': {'target'}, 'read_thread': {'target'},
    'list_threads': set(), 'list_sections': set(), 'list_projects': set(),
}
READ_OPERATIONS = {'status_thread', 'read_thread', 'list_threads', 'list_sections', 'list_projects'}


def clean_name(value, error, field='名称'):
    if (not isinstance(value, str) or not value.strip() or len(value) > 500 or
            any(unicodedata.category(char) in ('Cc', 'Cf', 'Cs') for char in value)):
        raise error('invalid_command_name', field + '必须是非空的单行文字。')
    return value.strip()


def validate_command(command, error):
    if not isinstance(command, dict) or command.get('operation') not in FIELDS:
        raise error('unsupported_desktop_operation', '这项操作还没有本地接口，未发送到对话。')
    operation = command['operation']
    expected = FIELDS[operation] | {'operation'}
    if set(command) != expected:
        raise error('invalid_desktop_command', '本地操作缺少必要名称，或带有无法识别的参数。')
    return {key: clean_name(value, error) if key != 'operation' else value
            for key, value in command.items()}


class DesktopActions:
    def __init__(self, pipe, source, request_id, call, read, tool_list, error, local_candidates=None):
        self.pipe, self.source, self.request_id = pipe, source, request_id
        self.call, self.read, self.error = call, read, error
        self.local_candidates = local_candidates
        self.dispatched = False
        tools = tool_list(pipe)
        if not isinstance(tools, dict) or not isinstance(tools.get('tools'), list):
            raise error('invalid_tool_catalog', '无法核实 Codex 本地操作接口。')
        self.tools = {item.get('name'): item for item in tools['tools']
                      if isinstance(item, dict) and item.get('namespace') == 'codex_app'}
        self.require('read_thread')
        self.source_info = self.read(pipe, source)
        self.check_identity(self.source_info, source)

    def require(self, tool):
        if tool not in self.tools:
            raise self.error('unsupported_app_version', '当前 Codex 版本没有这项本地接口，未发送到对话。')

    def invoke(self, tool, args, mutation=False):
        self.require(tool)
        if mutation:
            self.dispatched = True
        return self.call(self.pipe, tool, args, self.source,
                         request_id=self.request_id if mutation else None, mutation=mutation)

    def check_identity(self, info, target_id):
        if (not isinstance(info, dict) or info.get('threadId') != target_id or
                info.get('hostId') != 'local'):
            raise self.error('wrong_target', '无法核实本机 Codex 任务，请重新选择任务。')

    def catalog(self):
        data = self.invoke('list_threads', {'limit': 50})
        if (not isinstance(data, dict) or not all(isinstance(data.get(key), list)
                for key in ('threads', 'pinnedThreads', 'sections'))):
            raise self.error('invalid_thread_catalog', 'Codex 没有返回可核对的任务和分组列表。')
        # A missing local host cannot be treated as an empty, authoritative list.
        unavailable = data.get('unavailableHosts', [])
        if any(item == 'local' or isinstance(item, dict) and
               item.get('hostId', item.get('id')) == 'local' for item in unavailable):
            raise self.error('local_catalog_unavailable', '本机任务列表暂不可用，未执行操作。')
        sections = data['sections']
        if any(not isinstance(s, dict) or not isinstance(s.get('sectionId'), str) or
               not s['sectionId'] or not isinstance(s.get('name'), str) or
               not isinstance(s.get('itemKeys'), list) for s in sections):
            raise self.error('invalid_section_catalog', 'Codex 返回的分组信息不完整。')
        if len({s['sectionId'] for s in sections}) != len(sections):
            raise self.error('invalid_section_catalog', 'Codex 返回了重复分组标识。')
        return data

    @staticmethod
    def local_rows(data):
        seen, rows = set(), []
        for item in data.get('pinnedThreads', []) + data.get('threads', []):
            if (not isinstance(item, dict) or item.get('kind') != 'codex' or
                    item.get('hostId') != 'local'):
                continue
            try:
                task_id = str(uuid.UUID(item.get('id')))
            except (ValueError, AttributeError, TypeError):
                continue
            if task_id != item.get('id') or not isinstance(item.get('title'), str):
                continue
            if task_id not in seen:
                seen.add(task_id)
                rows.append(item)
        return rows

    def archived(self):
        result, cursor, seen = [], None, set()
        for _ in range(20):
            args = {'hostId': 'local', 'limit': 50}
            if cursor is not None:
                args['cursor'] = cursor
            page = self.invoke('list_archived_threads', args)
            if (not isinstance(page, dict) or not isinstance(page.get('threads'), list) or
                    'nextCursor' not in page):
                raise self.error('invalid_archived_catalog', '无法核实归档任务列表。')
            result.extend(self.local_rows({'threads': page['threads']}))
            cursor = page['nextCursor']
            if cursor is None:
                return result
            if not isinstance(cursor, str) or not cursor or cursor in seen:
                break
            seen.add(cursor)
        raise self.error('incomplete_archived_catalog', '归档列表过长或分页异常，无法唯一核对目标；请在 Codex 中恢复。')

    def complete_local_rows(self, data):
        """The desktop catalog may omit loaded/project tasks even below its cap.

        Existing read-only index discovery supplies candidate IDs, never final
        identity or names. Every catalog omission is validated with read_thread.
        """
        rows = {row['id']: row for row in self.local_rows(data)}
        rows[self.source] = {'id': self.source, 'title': self.source_info.get('title', ''),
                             'kind': 'codex', 'hostId': 'local'}
        if self.local_candidates is None:
            if len(data['threads']) >= 50:
                raise self.error('incomplete_thread_catalog', '任务列表超过接口范围，无法排除同名任务。请先切换并使用“当前对话”。')
            return list(rows.values())
        index = self.local_candidates()
        if not isinstance(index, dict) or not isinstance(index.get('threads'), list):
            raise self.error('incomplete_thread_catalog', '无法核对完整本机任务列表，请先选择目标并使用“当前对话”。')
        for candidate in index['threads']:
            if not isinstance(candidate, dict) or candidate.get('hostId') != 'local':
                raise self.error('invalid_local_candidate', '本机任务候选信息无法校验。')
            tid = candidate.get('threadId')
            try:
                if str(uuid.UUID(tid)) != tid:
                    raise ValueError('noncanonical ID')
            except (ValueError, AttributeError, TypeError):
                raise self.error('invalid_local_candidate', '本机任务候选标识无法校验。')
            if tid not in rows:
                info = self.read(self.pipe, tid)
                self.check_identity(info, tid)
                rows[tid] = {'id': tid, 'title': info.get('title', ''), 'kind': 'codex', 'hostId': 'local'}
        return list(rows.values())

    def target(self, name, data=None, archived=False):
        if name == 'current':
            return self.source_info
        if archived:
            rows = self.archived()
        else:
            data = data if data is not None else self.catalog()
            rows = self.complete_local_rows(data)
        matches = {row['id']: row for row in rows if row['title'].strip() == name}
        if not matches:
            raise self.error('thread_not_found', '没有找到这个名称的本机任务，请使用任务的完整名称。')
        if len(matches) != 1:
            raise self.error('ambiguous_thread', '有多个同名任务，未执行操作；请在声伴选择目标后使用“当前对话”。')
        task_id = next(iter(matches))
        info = self.read(self.pipe, task_id)
        self.check_identity(info, task_id)
        # A concurrent rename invalidates title selection instead of choosing a new task.
        if info.get('title', '').strip() != name:
            raise self.error('target_changed', '任务名称刚刚发生变化，请核对后重新操作。')
        return info

    def section(self, name, data):
        matches = [s for s in data['sections'] if s['name'].strip() == name]
        if len(matches) > 1:
            raise self.error('ambiguous_section', '有多个同名分组，请先在 Codex 修改为不同名称。')
        if not matches:
            raise self.error('section_not_found', '没有这个侧栏分组；项目与分组不同，请使用已有分组的完整名称。')
        if matches[0]['sectionId'] in BUILTIN_SECTIONS:
            raise self.error('builtin_section', '这是内置区域，请使用自定义分组；固定和取消固定有独立口令。')
        return matches[0]

    def result(self, operation, message, target=None, **fields):
        output = {'requestId': self.request_id, 'operation': operation, 'message': message}
        if target is not None:
            output.update(targetThreadId=target['threadId'], title=target.get('title', ''))
        output.update(fields)
        return output

    def verify(self, condition):
        if not condition:
            raise self.error('desktop_action_unknown', '操作已发出，但未能核实结果；请在 Codex 检查，程序不会重试。', True)

    def run(self, command):
        op = command['operation']
        if op == 'list_projects':
            data = self.invoke('list_projects', {})
            if not isinstance(data, dict) or not isinstance(data.get('projects'), list):
                raise self.error('invalid_projects_response', '无法读取本机项目列表。')
            projects = [{'projectId': p['projectId'], 'name': p['label']} for p in data['projects']
                        if isinstance(p, dict) and p.get('hostId') == 'local' and
                        p.get('projectKind') == 'local' and isinstance(p.get('projectId'), str) and
                        isinstance(p.get('label'), str)]
            return self.result(op, '本机项目：' + '、'.join(p['name'] for p in projects) + '。'
                               if projects else '没有已保存的本机项目。', projects=projects)
        if op in ('list_threads', 'list_sections'):
            data = self.catalog()
            if op == 'list_sections':
                sections = [{'sectionId': s['sectionId'], 'name': s['name']} for s in data['sections']
                            if s['sectionId'] not in BUILTIN_SECTIONS]
                return self.result(op, '侧栏分组：' + '、'.join(s['name'] for s in sections) + '。'
                                   if sections else '目前没有自定义侧栏分组。', sections=sections)
            threads = [{'threadId': t['id'], 'title': t['title']} for t in self.complete_local_rows(data)]
            return self.result(op, '当前列表中的本机任务：' + '、'.join(t['title'] for t in threads) + '。'
                               if threads else '当前列表中没有本机任务。', threads=threads,
                               mayBePartial=self.local_candidates is None)
        if op in ('create_section', 'rename_section', 'delete_section', 'section_to_top'):
            data = self.catalog()
            if op == 'create_section':
                matches = [s for s in data['sections'] if s['name'].strip() == command['name']]
                if matches:
                    existing = self.section(command['name'], data)
                    return self.result(op, '分组“' + existing['name'] + '”已经存在。',
                                       sectionId=existing['sectionId'], alreadyExists=True)
                self.invoke('create_sidebar_section', {'name': command['name']}, True)
                after = self.section(command['name'], self.catalog())
                return self.result(op, '已新建分组“' + after['name'] + '”。', sectionId=after['sectionId'])
            section = self.section(command['section'], data)
            sid = section['sectionId']
            if op == 'rename_section':
                new_name = command['newName']
                if any(s['name'].strip() == new_name and s['sectionId'] != sid for s in data['sections']):
                    raise self.error('section_name_taken', '已有同名分组，未改名。')
                if section['name'] != new_name:
                    self.invoke('rename_sidebar_section', {'sectionId': sid, 'name': new_name}, True)
                    self.verify(any(s['sectionId'] == sid and s['name'] == new_name
                                    for s in self.catalog()['sections']))
                return self.result(op, '分组名称已设为“' + new_name + '”。', sectionId=sid)
            if op == 'delete_section':
                self.invoke('delete_sidebar_section', {'sectionId': sid}, True)
                self.verify(all(s['sectionId'] != sid for s in self.catalog()['sections']))
                return self.result(op, '已删除分组“' + section['name'] + '”，其中的任务和项目仍保留。', sectionId=sid)
            custom_ids = [s['sectionId'] for s in data['sections'] if s['sectionId'] not in BUILTIN_SECTIONS]
            desired = [sid] + [item for item in custom_ids if item != sid]
            if desired != custom_ids:
                self.invoke('reorder_sidebar_sections', {'sectionIds': desired}, True)
                self.verify([s['sectionId'] for s in self.catalog()['sections']
                             if s['sectionId'] not in BUILTIN_SECTIONS] == desired)
            return self.result(op, '已把“' + section['name'] + '”移到自定义分组最上面。', sectionId=sid)

        target = self.target(command['target'], archived=op == 'restore_thread')
        tid = target['threadId']
        if op == 'status_thread':
            status = target.get('status', 'unknown')
            description = {'active': '正在处理', 'inProgress': '正在处理', 'running': '正在处理',
                           'idle': '当前空闲', 'notLoaded': '当前未加载', 'systemError': '发生系统错误',
                           'unknown': '暂时无法确定'}.get(status, '状态为 ' + str(status))
            return self.result(op, '“' + target.get('title', '') + '”' + description + '。', target, status=status)
        if op == 'read_thread':
            text = target.get('lastAssistantText')
            if target.get('lastAssistantTextTruncated'):
                return self.result(op, '这条回答超过读取接口长度，未能取得完整原文，请在 Codex 中查看。', target)
            if not isinstance(text, str) or not text.strip():
                return self.result(op, '最近可读取的记录中没有已完成的最终回答。', target)
            return self.result(op, '已读取最近完成的回答。', target, text=text)
        if op == 'rename_thread':
            name = command['name']
            if len(name) > 120:
                raise self.error('invalid_command_name', '任务新名称最多 120 个字符。')
            if target.get('title') != name:
                self.invoke('set_thread_title', {'threadId': tid, 'title': name}, True)
                after = self.read(self.pipe, tid)
                self.check_identity(after, tid)
                self.verify(after.get('title') == name)
            return self.result(op, '任务名称已设为“' + name + '”。', {**target, 'title': name})
        if op == 'open_thread':
            receipt = self.invoke('navigate_to_codex_page', {'threadId': tid}, True)
            self.verify(isinstance(receipt, dict) and receipt.get('navigated') is True)
            return self.result(op, '已打开“' + target.get('title', '') + '”。', target)
        if op in ('archive_thread', 'restore_thread'):
            if tid == self.source:
                raise self.error('current_archive_blocked', '请先把声伴切换到其他任务，再按名称归档或恢复这个任务。')
            if target.get('status') not in ('idle', 'notLoaded'):
                raise self.error('target_busy', '目标任务正在处理或状态未确定，请等任务空闲后操作。')
            archived = op == 'archive_thread'
            self.require('list_archived_threads')
            self.invoke('set_thread_archived', {'threadId': tid, 'hostId': 'local', 'archived': archived}, True)
            present = any(row['id'] == tid for row in self.archived())
            self.verify(present == archived)
            return self.result(op, ('已归档“' if archived else '已恢复“') + target.get('title', '') + '”。', target)
        if op in ('move_thread', 'pin_thread', 'unpin_thread'):
            data = self.catalog()
            key = 'codex:thread:local:' + tid
            if op == 'unpin_thread' and not any(s['sectionId'] == 'pinned' and key in s['itemKeys']
                                                for s in data['sections']):
                return self.result(op, '这个任务当前没有固定。', target, alreadyUnpinned=True)
            if op == 'move_thread':
                destination = self.section(command['section'], data)
                sid = destination['sectionId']
            else:
                sid = 'pinned' if op == 'pin_thread' else None
            def placed(catalog):
                if sid is None:
                    return all(key not in s['itemKeys'] for s in catalog['sections']
                               if s['sectionId'] not in ('threads', 'chats'))
                return any(s['sectionId'] == sid and key in s['itemKeys'] for s in catalog['sections'])
            if not placed(data):
                self.invoke('move_thread_to_sidebar_section', {'threadId': tid, 'hostId': 'local', 'sectionId': sid}, True)
                self.verify(placed(self.catalog()))
            message = ('已把任务放入分组“' + destination['name'] + '”。' if op == 'move_thread' else
                       '已固定这个任务。' if op == 'pin_thread' else '已取消固定，并移回默认任务区域。')
            return self.result(op, message, target, sectionId=sid)
        raise self.error('unsupported_desktop_operation', '没有这项本地操作。')


def manage_once(source, request_id, command, state_dir, connect, call, read, tool_list, error,
                local_candidates=None):
    """Reserve before any tool call; pending/unknown requests are never replayed.

    A second SQLite transaction serializes catalog+mutation across processes,
    including different request IDs creating the same section name.
    """
    command = validate_command(command, error)
    try:
        request_id = str(uuid.UUID(request_id)) if isinstance(request_id, str) else None
    except (ValueError, AttributeError):
        request_id = None
    if request_id is None:
        raise error('request_id_required', '本地操作必须带有稳定 requestId（UUID）。')
    digest = hashlib.sha256(json.dumps({'source': source, 'command': command}, ensure_ascii=False,
                                       sort_keys=True).encode('utf-8')).hexdigest()
    db, context, reserved = None, None, False
    try:
        root = Path(state_dir).resolve()
        root.mkdir(parents=True, exist_ok=True)
        db = sqlite3.connect(root / LEDGER_NAME, timeout=5)
        db.row_factory = sqlite3.Row
        db.execute('CREATE TABLE IF NOT EXISTS actions (request_id TEXT PRIMARY KEY, digest TEXT NOT NULL, '
                   'state TEXT NOT NULL, result TEXT, created REAL NOT NULL)')
        db.commit()
        db.execute('BEGIN IMMEDIATE')
        prior = db.execute('SELECT * FROM actions WHERE request_id=?', (request_id,)).fetchone()
        if prior:
            db.rollback()
            if prior['digest'] != digest:
                raise error('request_id_conflict', '同一 requestId 不能用于不同的本地操作。', True)
            if prior['state'] == 'accepted':
                try:
                    result = json.loads(prior['result'])
                    if result['requestId'] != request_id or result['operation'] != command['operation']:
                        raise ValueError('receipt identity mismatch')
                    return {**result, 'duplicateSuppressed': True}
                except (ValueError, KeyError, TypeError):
                    raise error('desktop_action_unknown', '操作记录无法核实，请在 Codex 查看；不会重复操作。', True)
            raise error('duplicate_suppressed', '这条操作已处理或结果未确认，已阻止重复执行，请在 Codex 核对。',
                        prior['state'] in ('pending', 'unknown'))
        db.execute('INSERT INTO actions VALUES (?,?,?,?,?)', (request_id, digest, 'pending', None, time.time()))
        db.commit()
        reserved = True
        db.execute('BEGIN IMMEDIATE')
        context = DesktopActions(connect(), source, request_id, call, read, tool_list, error, local_candidates)
        result = context.run(command)
        result['duplicateSuppressed'] = False
        db.execute('UPDATE actions SET state=?,result=? WHERE request_id=?',
                   ('accepted', json.dumps(result, ensure_ascii=False), request_id))
        db.commit()
        return result
    except error as exc:
        uncertain = exc.uncertain or bool(context and context.dispatched)
        if reserved and db is not None:
            try:
                db.execute('UPDATE actions SET state=? WHERE request_id=?',
                           ('unknown' if uncertain else 'rejected', request_id))
                db.commit()
            except sqlite3.Error:
                db.rollback()
                uncertain = True
        if uncertain and not exc.uncertain:
            raise error('desktop_action_unknown', '操作已发出，但结果未能核实；请在 Codex 检查，程序不会重试。', True) from exc
        raise
    except Exception as exc:
        uncertain = bool(context and context.dispatched)
        if reserved and db is not None:
            try:
                db.execute('UPDATE actions SET state=? WHERE request_id=?',
                           ('unknown' if uncertain else 'rejected', request_id))
                db.commit()
            except sqlite3.Error:
                db.rollback()
                uncertain = True
        raise error('desktop_action_unknown' if uncertain else 'desktop_action_failed',
                    '结果未能核实，请在 Codex 检查，程序不会重试。' if uncertain else
                    '本地操作未执行成功，请检查 Codex 连接和任务信息。', uncertain) from exc
    finally:
        if db is not None:
            db.close()
