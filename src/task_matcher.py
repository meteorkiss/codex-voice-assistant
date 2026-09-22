"""Conservative, title-only matching for local Codex task candidates.

Matching precedence is normalized full title, literal title substring, explicit
keyword intersection, a version-qualified known product alias, then an exact
window of Mandarin syllables (tones ignored).
Approximate results are suggestions requiring confirmation, never binding
decisions. No initials, word dropping or title-summary search is performed.
A bare two-part version can omit only the zero major version.
"""
from __future__ import annotations

import unicodedata
import re
from difflib import SequenceMatcher

MAX_QUERY_LENGTH = 200
MAX_CANDIDATES = 5
MIN_PHONETIC_HAN = 3
VERSION_TOKEN = re.compile(r'v[0-9]+(?:\.[0-9]+)*|[0-9]+(?:\.[0-9]+)+')
VERSIONED_PRODUCT_ALIASES = {'申办': '声伴', '生办': '声伴'}


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
    folded = ''.join(char for char in unicodedata.normalize('NFKC', value).casefold()
                     if not char.isspace())
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


def version_matches(query_version, title_version):
    """Compare complete version tokens, never an arbitrary digit substring.

    An explicit v prefix is exact. A bare 6.17 may mean 6.17 or 0.6.17,
    but not 1.6.17, 16.17, 6.170, or 6.17.1. Missing dots are not inferred.
    """
    if query_version.startswith('v'):
        return query_version == title_version
    title_number = title_version.removeprefix('v')
    if query_version == title_number:
        return True
    parts = query_version.split('.')
    return (len(parts) == 2 and parts[0] != '0' and
            title_number == '0.' + query_version)


def keyword_terms(query):
    """Split only explicit whitespace and numeric version boundaries.

    Split Han/Latin script boundaries without segmenting Chinese words. A short Han fragment
    does not gain phonetic guessing merely because it appears with another word.
    Spacing inside a spoken version (v 0 . 6 . 17) remains insignificant.
    """
    folded = unicodedata.normalize('NFKC', query).casefold()
    folded = re.sub(r'(?<=[0-9])\s*\.\s*(?=[0-9])', '.', folded)
    folded = re.sub(r'v\s+(?=[0-9])', 'v', folded)
    terms = []
    for part in folded.split():
        normalized = normalize_title(part)
        start = 0
        for match in VERSION_TOKEN.finditer(normalized):
            if match.start() > start:
                terms.extend((word, False) for word in script_terms(normalized[start:match.start()]))
            terms.append((match.group(), True))
            start = match.end()
        if start < len(normalized):
            terms.extend((word, False) for word in script_terms(normalized[start:]))
    return terms


def script_terms(text):
    # Retain punctuation/digits attached to Latin names (C++, C#, GPT4).
    return re.findall(r'[a-z0-9+#.]+|[^a-z0-9+#.]+', text)


def matches_omitted_conjunction(word, title_words):
    """Allow one title-side 与/和 gap between literal Han spans of >=2 chars.

    No query character, negation, content word or version is discarded. This
    only recalls confirmation candidates, never changes exact normalization.
    """
    if len(word) < 4 or not all(is_han(char) for char in word):
        return False
    return any(word[:split] + conjunction + word[split:] in title_word
               for split in range(2, len(word) - 1)
               for conjunction in ('与', '和') for title_word in title_words)


def approximate_keywords(terms, title, title_versions):
    """Conservative local candidate recall; every keyword must be explained.

    Only ASCII words of at least four letters allow small spelling deviations.
    Chinese homophones need three Han characters; short words stay literal.
    Numeric tokens are never fuzzy. Similarity is not a probability.
    """
    title_words = [word for word, is_version in keyword_terms(title) if not is_version]
    normalized = normalize_title(title)
    scores = []
    for word, is_version in terms:
        if is_version:
            if not any(version_matches(word, item) for item in title_versions):
                return None
            scores.append(1.0)
        elif word in normalized:
            scores.append(1.0)
        elif matches_omitted_conjunction(word, title_words):
            scores.append(0.85)
        elif re.fullmatch(r'[a-z]{4,}', word):
            options = [SequenceMatcher(None, word, other, autojunk=False).ratio()
                       for other in title_words if re.fullmatch(r'[a-z]{4,}', other)
                       and abs(len(word) - len(other)) <= 2]
            best = max(options, default=0.0)
            if best < 0.8:
                return None
            scores.append(best)
        elif len(word) >= MIN_PHONETIC_HAN and all(is_han(char) for char in word):
            if not contains_window(phonetic_units(normalized), phonetic_units(word)):
                return None
            scores.append(0.9)
        else:
            return None
    return sum(scores) / len(scores) if scores else None


def keywords_match(terms, title, title_versions):
    return bool(terms) and all(
        any(version_matches(term, title_version) for title_version in title_versions)
        if is_version else term in title
        for term, is_version in terms)


def known_alias_terms(terms):
    """Observed ASR product aliases, only with an explicit version token.

    Both product names must remain whole keyword terms: never replace part of
    a longer name, remove another keyword, or correct any version digit.
    """
    if not any(is_version for _, is_version in terms):
        return [], set()
    replacements = {term: VERSIONED_PRODUCT_ALIASES[term] for term, is_version in terms
                    if not is_version and term in VERSIONED_PRODUCT_ALIASES}
    if not replacements:
        return [], set()
    return ([(replacements.get(term, term) if not is_version else term, is_version)
             for term, is_version in terms], set(replacements.values()))


def match_tasks(query, threads):
    """Return original candidates in index order, capped at five on ambiguity.

    Input candidates come from codex_bridge.list_tasks, which already checks
    local host, UUID, archive/agent flags, and rollout path. The returned match
    is still an index candidate and needs the existing live read validation
    before the caller can bind it.
    """
    query, normalized = validate_query(query)
    terms = keyword_terms(query)
    titled = [(thread, normalize_title(thread['title']),
               [term for term, is_version in keyword_terms(thread['title']) if is_version])
              for thread in threads
              if isinstance(thread, dict) and isinstance(thread.get('title'), str)]
    # Every matching mode observes numeric boundaries, including a bare version
    # fragment. Spacing was removed above without dropping digit dots.
    versions = [term for term, is_version in terms if is_version]
    if versions:
        titled = [(thread, title, title_versions) for thread, title, title_versions in titled
                  if all(any(version_matches(version, title_version)
                             for title_version in title_versions)
                         for version in versions)]
    matches = [thread for thread, title, _ in titled if title == normalized]
    method = 'exact'
    if not matches:
        method = 'contains'
        matches = [thread for thread, title, _ in titled if normalized in title]
    if not matches:
        method = 'keywords'
        matches = [thread for thread, title, title_versions in titled
                   if keywords_match(terms, title, title_versions)]
    if not matches:
        alias_terms, products = known_alias_terms(terms)
        if alias_terms:
            method = 'known_alias'
            matches = [thread for thread, title, title_versions in titled
                       if all((product, False) in keyword_terms(thread['title']) for product in products)
                       and keywords_match(alias_terms, title, title_versions)]
    if not matches and titled and sum(is_han(char) for char in normalized) >= MIN_PHONETIC_HAN:
        method = 'phonetic'
        needle = phonetic_units(normalized)
        matches = [thread for thread, title, _ in titled
                   if len(title) >= len(normalized) and
                   contains_window(phonetic_units(title), needle)]
    if not matches:
        method = 'approximate_keywords'
        ranked = []
        for order, (thread, _, title_versions) in enumerate(titled):
            score = approximate_keywords(terms, thread['title'], title_versions)
            if score is None:
                alias_terms, products = known_alias_terms(terms)
                if alias_terms and all((product, False) in keyword_terms(thread['title'])
                                       for product in products):
                    score = approximate_keywords(alias_terms, thread['title'], title_versions)
                    if score is not None:
                        score -= 0.05
            if score is not None:
                ranked.append((-score, order, thread))
        matches = [thread for _, _, thread in sorted(ranked, key=lambda item: item[:2])]
    total = len(matches)
    return {'query': query, 'matchType': 'unique' if total == 1 else 'ambiguous' if total else 'none',
            'matchMethod': method if total else 'none', 'threads': matches[:MAX_CANDIDATES],
            'totalMatches': total,
            'requiresConfirmation': bool(total and method in ('known_alias', 'phonetic', 'approximate_keywords'))}
