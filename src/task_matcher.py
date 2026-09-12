"""Conservative, title-only matching for local Codex task candidates.

Matching precedence is normalized full title, literal title substring, then an
exact window of Mandarin syllables (tones ignored). No edit distance, initials,
word dropping, title-summary search, or task switching is performed here.
"""
from __future__ import annotations

import unicodedata

MAX_QUERY_LENGTH = 200
MAX_CANDIDATES = 5
MIN_PHONETIC_HAN = 3


class TaskMatchError(ValueError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def normalize_title(value):
    """NFKC + casefold; ignore spacing and ordinary sentence punctuation.

    Digits and Latin letters remain significant, so V2 cannot match V3.
    Keep +/# and dots between digits: C++/C# and V2.1/V21 are different titles.
    No command phrases, fillers, or common words are removed.
    """
    folded = unicodedata.normalize('NFKC', value).casefold()
    return ''.join(char for index, char in enumerate(folded)
                   if unicodedata.category(char)[0] in 'LN' or char in '+#' or
                   (char == '.' and 0 < index < len(folded) - 1 and
                    folded[index - 1].isdigit() and folded[index + 1].isdigit()))


def validate_query(value):
    if not isinstance(value, str) or len(value) > MAX_QUERY_LENGTH:
        raise TaskMatchError('invalid_query', '请提供不超过 200 个字符的任务标题或关键词。')
    # Invisible controls must not create a title different from what is shown.
    if any(unicodedata.category(char) in ('Cc', 'Cf', 'Cs') and
           char not in '\t\r\n' for char in value):
        raise TaskMatchError('invalid_query', '任务关键词不能包含不可见控制字符。')
    query = value.strip()
    normalized = normalize_title(query)
    if sum(unicodedata.category(char)[0] in 'LN' for char in normalized) < 2:
        raise TaskMatchError('invalid_query', '任务关键词至少需要两个有效文字或数字，请说得更完整一些。')
    return query, normalized


def is_han(char):
    name = unicodedata.name(char, '')
    return name.startswith(('CJK UNIFIED IDEOGRAPH-', 'CJK COMPATIBILITY IDEOGRAPH-')) or char == '〇'


def phonetic_units(text):
    """Preserve syllable and script boundaries, including literal Latin/digits.

    Phrase-aware pypinyin keeps its normal context-dependent pronunciation. We
    deliberately do not expand every polyphonic reading: that would produce
    weak matches. Unknown Han characters retain their literal spelling.
    """
    try:
        from pypinyin import Style, lazy_pinyin
    except ImportError as exc:
        raise TaskMatchError('phonetic_matching_unavailable',
                             '同音任务查找组件不可用，请输入准确标题或修复 pypinyin 依赖。') from exc
    syllables = lazy_pinyin(text, style=Style.NORMAL, errors=lambda part: list(part),
                            strict=True)
    if len(syllables) != len(text):
        raise TaskMatchError('phonetic_matching_unavailable',
                             '同音任务查找返回了无法校验的结果，请输入准确标题。')
    return tuple(('han:' if is_han(char) else 'literal:') + syllable
                 for char, syllable in zip(text, syllables))


def contains_window(haystack, needle):
    width = len(needle)
    return any(haystack[start:start + width] == needle
               for start in range(len(haystack) - width + 1))


def match_tasks(query, threads):
    """Return original candidates in index order, capped at five on ambiguity.

    Input candidates come from codex_bridge.list_tasks, which already checks
    local host, UUID, archive/agent flags, and rollout path. The returned match
    is still an index candidate and needs the existing live read validation
    before the caller can bind it.
    """
    query, normalized = validate_query(query)
    titled = [(thread, normalize_title(thread['title'])) for thread in threads
              if isinstance(thread, dict) and isinstance(thread.get('title'), str)]
    matches = [thread for thread, title in titled if title == normalized]
    method = 'exact'
    if not matches:
        method = 'contains'
        matches = [thread for thread, title in titled if normalized in title]
    if not matches and titled and sum(is_han(char) for char in normalized) >= MIN_PHONETIC_HAN:
        method = 'phonetic'
        needle = phonetic_units(normalized)
        matches = [thread for thread, title in titled
                   if len(title) >= len(normalized) and
                   contains_window(phonetic_units(title), needle)]
    total = len(matches)
    return {'query': query, 'matchType': 'unique' if total == 1 else 'ambiguous' if total else 'none',
            'matchMethod': method if total else 'none', 'threads': matches[:MAX_CANDIDATES],
            'totalMatches': total}
