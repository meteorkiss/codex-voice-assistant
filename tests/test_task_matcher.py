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

    def test_bare_version_fragment_supports_only_complete_or_zero_major_version(self):
        for title in ('声伴 v0.6.17 · 短时连续接话', '声伴 V6.17', '声伴 6.17', '声伴 0.6.17'):
            with self.subTest(title=title):
                expected = task(title)
                out = matcher.match_tasks('6.17', [expected])
                self.assertEqual(out['matchType'], 'unique')
                self.assertEqual(out['threads'], [expected])
                self.assertIs(out['threads'][0], expected)

    def test_bare_version_fragment_never_matches_other_numeric_boundaries(self):
        for query in ('6.17', '声伴 6.17', '6.17 声伴', '声伴6.17'):
            for version in ('6.170', '16.17', '6.17.1', '0.6.170', '0.6.17.1',
                            '1.6.17', '10.6.17', '06.17', '0.06.17'):
                with self.subTest(query=query, version=version):
                    self.assertEqual(matcher.match_tasks(
                        query, [task('声伴 v' + version)])['matchType'], 'none')

    def test_dots_and_explicit_major_versions_are_not_guessed(self):
        expected = task('声伴 v0.6.17 · 短时连续接话')
        for query in ('617', '声伴 617', '声伴 V6.17', '声伴 00.6.17', '声伴 V0.617'):
            with self.subTest(query=query):
                self.assertEqual(matcher.match_tasks(query, [expected])['matchType'], 'none')

    def test_name_and_bare_version_are_combined_without_rewriting_the_title(self):
        expected = task('声伴 v0.6.17 · 短时连续接话')
        rows = [task('其它 v0.6.17'), task('声伴 v0.6.16'), expected]
        for query in ('声伴 6.17', '6.17 声伴', '声伴6.17', '声伴 ６．１７'):
            with self.subTest(query=query):
                out = matcher.match_tasks(query, rows)
                self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'keywords'))
                self.assertEqual(out['query'], query)
                self.assertEqual(out['threads'], [expected])
                self.assertEqual(out['threads'][0]['title'], '声伴 v0.6.17 · 短时连续接话')

    def test_explicit_keyword_intersection_supports_nonadjacent_terms_in_any_order(self):
        expected = task('高斯泼溅 · 场景制作 · 性能优化')
        rows = [task('高斯泼溅 · 示例'), task('声伴 · 性能优化'), expected]
        for query in ('高斯泼溅 性能优化', '性能优化 高斯泼溅', '高斯泼溅 场景 性能'):
            with self.subTest(query=query):
                out = matcher.match_tasks(query, rows)
                self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'keywords'))
                self.assertEqual(out['threads'], [expected])

    def test_keyword_intersection_never_drops_an_unmatched_word(self):
        expected = task('高斯泼溅 · 性能优化')
        for query in ('高斯泼溅 其它', '帮我找 高斯泼溅', '高斯泼溅 性能优化 不存在'):
            with self.subTest(query=query):
                self.assertEqual(matcher.match_tasks(query, [expected])['matchType'], 'none')

    def test_literal_full_title_and_contiguous_matches_still_take_precedence(self):
        other = task('高斯泼溅 · 场景制作 · 性能优化')
        for title, method in (('高斯泼溅性能优化', 'exact'), ('高斯泼溅性能优化测试', 'contains')):
            with self.subTest(title=title):
                expected = task(title)
                out = matcher.match_tasks('高斯泼溅 性能优化', [other, expected])
                self.assertEqual((out['matchType'], out['matchMethod']), ('unique', method))
                self.assertEqual(out['threads'], [expected])

    def test_same_bare_version_matches_all_candidates_and_preserves_cap(self):
        rows = [task(f'声伴 v0.6.17 · 方案 {number}') for number in range(8)]
        for query in ('6.17', '声伴 6.17', '声伴'):
            with self.subTest(query=query):
                out = matcher.match_tasks(query, rows)
                self.assertEqual((out['matchType'], out['totalMatches']), ('ambiguous', 8))
                self.assertEqual(out['threads'], rows[:5])

    def test_multiple_explicit_versions_must_all_match(self):
        expected = task('声伴 v0.6.17 与 v0.6.18 · 对比')
        out = matcher.match_tasks('声伴 6.17 6.18',
                                  [task('声伴 v0.6.17 · 单版'), expected])
        self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'keywords'))
        self.assertEqual(out['threads'], [expected])

    def test_keyword_intersection_does_not_add_short_phonetic_guessing(self):
        self.assertEqual(matcher.match_tasks(
            '高思 6.17', [task('高斯 v0.6.17')])['matchType'], 'none')

    def test_literal_keyword_matching_does_not_require_pinyin(self):
        expected = task('声伴 v0.6.17 · 短时连续接话')
        with patch.object(matcher, 'phonetic_units', side_effect=AssertionError('not needed')):
            out = matcher.match_tasks('声伴 6.17', [expected])
        self.assertEqual(out['threads'], [expected])

    def test_observed_product_alias_requires_version_and_preserves_original_query_and_title(self):
        expected = task('声伴 v0.6.17 · 短时连续接话')
        for query in ('申办0.6.17', '申办 6.17', '6.17 申办', '申办 ｖ０．６．１７'):
            with self.subTest(query=query):
                out = matcher.match_tasks(query, [expected])
                self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'known_alias'))
                self.assertEqual(out['query'], query)
                self.assertIs(out['threads'][0], expected)
                self.assertEqual(out['threads'][0]['title'], '声伴 v0.6.17 · 短时连续接话')

    def test_product_alias_is_not_tied_to_one_version_or_task_id(self):
        for version in ('v2', 'v1.2.3', '0.7.19'):
            with self.subTest(version=version):
                expected = task('声伴' + version + ' · 新版')
                out = matcher.match_tasks('申办' + version, [expected])
                self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'known_alias'))
                self.assertEqual(out['threads'], [expected])

    def test_literal_alias_names_always_precede_product_correction(self):
        product = task('声伴 v0.6.17 · 短时连续接话')
        for title, query, method in (
                ('申办0.6.17', '申办0.6.17', 'exact'),
                ('普通申办0.6.17项目', '申办0.6.17', 'contains'),
                ('申办 · 项目说明 · v0.6.17', '申办 6.17', 'keywords')):
            with self.subTest(title=title):
                expected = task(title)
                out = matcher.match_tasks(query, [product, expected])
                self.assertEqual((out['matchType'], out['matchMethod']), ('unique', method))
                self.assertEqual(out['threads'], [expected])

    def test_product_alias_cannot_drop_additional_keywords(self):
        expected = task('声伴 v0.6.17 · 短时连续接话')
        other = task('声伴 v0.6.17 · 安装')
        out = matcher.match_tasks('申办 6.17 短时', [other, expected])
        self.assertEqual((out['matchType'], out['matchMethod']), ('unique', 'known_alias'))
        self.assertEqual(out['threads'], [expected])
        for query in ('申办 6.17 不存在', '申办 6.17 短时 不存在'):
            with self.subTest(query=query):
                self.assertEqual(matcher.match_tasks(query, [expected])['matchType'], 'none')

    def test_product_alias_never_guesses_or_corrects_version_digits(self):
        for query in ('申办6.117', '申办0.6.117', '申办617', '申办v617',
                      '申办 16.17', '申办 0.6.170', '申办 6.17.1'):
            with self.subTest(query=query):
                self.assertEqual(matcher.match_tasks(
                    query, [task('声伴 v0.6.17 · 短时连续接话')])['matchType'], 'none')
        for title in ('声伴 v0.6.170', '声伴 v6.17.1', '声伴 v0.6.17.1', '声伴 v16.17'):
            with self.subTest(title=title):
                self.assertEqual(matcher.match_tasks('申办6.17', [task(title)])['matchType'], 'none')
        exact_wrongly_heard_version = task('声伴 v0.6.117')
        self.assertEqual(matcher.match_tasks('申办6.117', [exact_wrongly_heard_version])['threads'],
                         [exact_wrongly_heard_version])

    def test_product_alias_only_replaces_whole_product_terms(self):
        for query, title in (('申办', '声伴'), ('申办', '声伴 v0.6.17'),
                             ('申办项目0.6.17', '声伴项目 v0.6.17'),
                             ('申办0.6.17', '无声伴奏 v0.6.17'),
                             ('申办0.6.17', '声伴侣 v0.6.17'),
                             ('神办0.6.17', '声伴 v0.6.17')):
            with self.subTest(query=query, title=title):
                self.assertEqual(matcher.match_tasks(query, [task(title)])['matchType'], 'none')

    def test_product_alias_ambiguity_keeps_all_matches_and_existing_cap(self):
        rows = [task(f'声伴 v0.6.17 · 方案 {number}') for number in range(8)]
        out = matcher.match_tasks('申办6.17', rows)
        self.assertEqual((out['matchType'], out['matchMethod'], out['totalMatches']),
                         ('ambiguous', 'known_alias', 8))
        self.assertEqual(out['threads'], rows[:5])

    def test_product_alias_does_not_enable_generic_two_han_phonetics(self):
        with patch.object(matcher, 'phonetic_units', side_effect=AssertionError('not needed')):
            self.assertEqual(matcher.match_tasks('申办', [task('声伴 v0.6.17')])['matchType'], 'none')
            self.assertEqual(matcher.match_tasks('高思6.17', [task('高斯 v0.6.17')])['matchType'], 'none')
            self.assertEqual(matcher.match_tasks('申办6.17', [task('声伴 v0.6.17')])['matchMethod'],
                             'known_alias')

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
