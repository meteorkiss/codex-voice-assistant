"""Synthetic title fixtures only; no Codex connection, audio, or task changes."""
from pathlib import Path
import sys
import unittest
from unittest.mock import patch
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
import task_matcher as matcher


def task(title, **extra):
    return {'threadId': str(uuid.uuid4()), 'title': title, 'cwd': 'C:\\synthetic-project',
            'rolloutPath': 'C:\\synthetic-rollout.jsonl', 'hostId': 'local',
            'status': 'unknown', 'requiresValidation': True, **extra}


class TitleMatchingTests(unittest.TestCase):
    def test_exact_title_takes_precedence_over_longer_title(self):
        exact = task('声波设置')
        out = matcher.match_tasks('声波设置', [task('声波设置的测试'), exact])
        self.assertEqual(out['matchType'], 'unique')
        self.assertEqual(out['matchMethod'], 'exact')
        self.assertEqual(out['threads'], [exact])
        self.assertIs(out['threads'][0], exact)

    def test_nfkc_case_and_punctuation_keep_original_display_title(self):
        title = 'ＡＰＩ　V２：语音助手！'
        expected = task(title)
        out = matcher.match_tasks(' api v2语音助手 ', [expected])
        self.assertEqual(out['matchMethod'], 'exact')
        self.assertEqual(out['query'], 'api v2语音助手')
        self.assertEqual(out['threads'][0]['title'], title)

    def test_unique_title_substring(self):
        expected = task('请帮忙检查桌面声波窗口的置顶状态')
        out = matcher.match_tasks('声波窗口', [task('接口实现'), expected])
        self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'contains'))
        self.assertEqual(out['threads'], [expected])

    def test_two_han_literal_substring_is_supported(self):
        expected = task('桌面窗口的配置')
        self.assertEqual(matcher.match_tasks('桌面', [expected])['threads'], [expected])

    def test_homophone_window_finds_asr_transcription(self):
        expected = task('请解释这个高斯破渐算法，再看看能否用于 V2 项目')
        out = matcher.match_tasks('高斯坡建', [task('声波窗口测试'), expected])
        self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'phonetic'))
        self.assertEqual(out['threads'], [expected])
        self.assertEqual(out['totalMatches'], 1)

    def test_phonetic_window_preserves_latin_and_version_numbers(self):
        expected = task('高斯破渐V2实验')
        self.assertEqual(matcher.match_tasks('高斯坡建v2', [expected])['threads'], [expected])
        self.assertEqual(matcher.match_tasks('高斯坡建V3', [expected])['matchType'], 'none')

    def test_technical_symbols_do_not_collapse_different_task_names(self):
        for query, title in (('C++接口', 'C#接口'), ('V2.1窗口', 'V21窗口')):
            with self.subTest(query=query, title=title):
                self.assertEqual(matcher.match_tasks(query, [task(title)])['matchType'], 'none')

    def test_spoken_version_spacing_preserves_query_and_original_display_title(self):
        expected = task('声伴 v0.6.17 · 短时连续接话')
        for query in ('声伴V0.6.17', '声伴 V 0 . 6 . 17', '声伴 ｖ０．６．１７'):
            with self.subTest(query=query):
                out = matcher.match_tasks(query, [task('声伴 v0.6.16 · 已完成'), expected])
                self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'contains'))
                self.assertEqual(out['query'], query)
                self.assertEqual(out['threads'], [expected])
                self.assertEqual(out['threads'][0]['title'], '声伴 v0.6.17 · 短时连续接话')

    def test_explicit_versions_never_match_a_longer_version_prefix(self):
        for query, title in (
                ('声伴V0.6.17', '声伴 v0.6.170 · 其它版本'),
                ('声伴 V 0 . 6 . 17', '声伴 v0.6.17.1 · 补丁'),
                ('声伴V0.6.17', '声伴 v06.17 · 其它版本'),
                ('高斯坡建V2', '高斯破渐V20实验'),
                ('高斯坡建V0.6.17', '高斯破渐V0.6.170实验')):
            with self.subTest(query=query, title=title):
                self.assertEqual(matcher.match_tasks(query, [task(title)])['matchType'], 'none')

    def test_same_version_candidates_remain_ambiguous(self):
        rows = [task('声伴 v0.6.17 · 短时连续接话'), task('声伴 V0.6.17 · 验收')]
        out = matcher.match_tasks('声伴V0.6.17', rows)
        self.assertEqual((out['matchType'], out['totalMatches']), ('ambiguous', 2))
        self.assertEqual(out['threads'], rows)

    def test_syllables_do_not_merge_across_character_boundaries(self):
        self.assertEqual(matcher.match_tasks('西安设', [task('先设计工具')])['matchType'], 'none')

    def test_no_romanization_or_initial_abbreviation_guessing(self):
        for query in ('gaosipojian', 'gspj'):
            with self.subTest(query=query):
                self.assertEqual(matcher.match_tasks(query, [task('高斯破渐')])['matchType'], 'none')

    def test_no_weak_edit_distance_or_word_reordering(self):
        for query in ('高斯坡角', '坡建高斯'):
            with self.subTest(query=query):
                self.assertEqual(matcher.match_tasks(query, [task('高斯破渐')])['matchType'], 'none')

    def test_no_filler_or_command_word_removal(self):
        self.assertEqual(matcher.match_tasks('帮我找声波窗口', [task('声波窗口')])['matchType'], 'none')

    def test_two_han_phonetic_match_is_too_weak(self):
        with patch.object(matcher, 'phonetic_units') as phonetic:
            out = matcher.match_tasks('高思', [task('高斯算法')])
        self.assertEqual(out['matchType'], 'none')
        phonetic.assert_not_called()

    def test_summary_and_cwd_never_participate_in_match(self):
        rows = [task('无关标题', summary='高斯坡建', cwd='C:\\高斯坡建')]
        self.assertEqual(matcher.match_tasks('高斯坡建', rows)['threads'], [])

    def test_duplicate_visible_titles_are_ambiguous(self):
        rows = [task('配置窗口'), task('配置窗口')]
        out = matcher.match_tasks('配置窗口', rows)
        self.assertEqual((out['matchType'], out['totalMatches']), ('ambiguous', 2))
        self.assertEqual(out['threads'], rows)

    def test_all_phonetic_matches_are_candidates_not_best_guess(self):
        rows = [task('高斯破渐研究'), task('高思破建测试')]
        out = matcher.match_tasks('高斯坡建', rows)
        self.assertEqual((out['matchType'], out['matchMethod']), ('ambiguous', 'phonetic'))
        self.assertEqual(out['threads'], rows)

    def test_ambiguous_results_cap_at_five_and_keep_total_and_order(self):
        rows = [task(f'声波窗口方案 {number}') for number in range(8)]
        out = matcher.match_tasks('声波窗口', rows)
        self.assertEqual((out['matchType'], out['totalMatches']), ('ambiguous', 8))
        self.assertEqual(out['threads'], rows[:5])

    def test_no_match_or_empty_index_is_successful_none(self):
        for rows in ([], [task('毫不相干')], [task(''), task(None)]):
            with self.subTest(rows=rows):
                out = matcher.match_tasks('声波窗口', rows)
                self.assertEqual((out['matchType'], out['matchMethod']), ('none', 'none'))
                self.assertEqual(out['totalMatches'], 0)
                self.assertEqual(out['threads'], [])

    def test_bad_queries_fail_clearly(self):
        for query in (None, 12, True, [], {}, '', '  ', '高', 'a', '高。',
                      '！？', '👋👋', '++', '高++', '标题\x00', '声\u200b波', 'x' * 201):
            with self.subTest(query=query), self.assertRaises(matcher.TaskMatchError) as caught:
                matcher.match_tasks(query, [task('正常任务')])
            self.assertEqual(caught.exception.code, 'invalid_query')

    def test_200_character_limit_is_inclusive(self):
        expected = task('x' * 200)
        self.assertEqual(matcher.match_tasks('x' * 200, [expected])['threads'], [expected])

    def test_literal_matches_do_not_require_pinyin_dependency(self):
        with patch.object(matcher, 'phonetic_units', side_effect=AssertionError('not needed')):
            self.assertEqual(matcher.match_tasks('声波', [task('声波窗口')])['matchType'], 'unique')
            self.assertEqual(matcher.match_tasks('声波窗口', [])['matchType'], 'none')

    def test_phonetic_dependency_failure_is_explicit_not_no_matches(self):
        with patch.dict(sys.modules, {'pypinyin': None}):
            with self.assertRaises(matcher.TaskMatchError) as caught:
                matcher.match_tasks('高斯坡建', [task('高斯破渐')])
        self.assertEqual(caught.exception.code, 'phonetic_matching_unavailable')


if __name__ == '__main__':
    unittest.main()
