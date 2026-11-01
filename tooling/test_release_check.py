"""Tests for tooling/release_check.py.

    python3 -m unittest discover -s tooling -p 'test_*.py'
"""

import unittest

from release_check import CheckError, check, parse_version, sort_key


def tags(*versions, commit=None):
    """Distinct commits by default: sharing one is the thing being tested."""
    if commit is not None:
        return {v: commit for v in versions}
    return {v: f"c{i:02d}" for i, v in enumerate(versions)}


class ParseVersionTest(unittest.TestCase):
    def test_name_and_build(self):
        self.assertEqual(parse_version("1.0.7+10311835"), ("1.0.7", "10311835"))
        self.assertEqual(parse_version("1.2.0"), ("1.2.0", None))
        self.assertEqual(parse_version("1.3.0-beta.1+10251234"), ("1.3.0-beta.1", "10251234"))

    def test_garbage(self):
        for text in ["", "v", "latest", "1.2", "1.2.0.1"]:
            with self.assertRaises(CheckError):
                parse_version(text)

    def test_pre_release_sorts_before_its_release(self):
        self.assertLess(sort_key("1.3.0-beta.1"), sort_key("1.3.0"))
        self.assertLess(sort_key("1.2.0"), sort_key("1.3.0-beta.1"))
        self.assertGreater(sort_key("1.10.0"), sort_key("1.9.9"))


class CheckTest(unittest.TestCase):
    def test_a_consistent_tree_has_no_problems(self):
        self.assertEqual(check("1.0.7+10311835", ["1.0.7", "1.0.6"], tags("1.0.5", "1.0.6", "1.0.7")), [])

    def test_a_prepared_release_is_fine(self):
        # pubspec bumped for the next release; the newest tag is still the previous one.
        self.assertEqual(check("1.1.0+1", ["1.1.0", "1.0.7"], tags("1.0.6", "1.0.7")), [])

    def test_changelog_behind_pubspec(self):
        problems = check("1.0.7+1", ["1.0.4"], tags("1.0.4", "1.0.7"))
        self.assertTrue(any("newest entry is 1.0.4" in p for p in problems), problems)

    def test_repository_behind_its_releases(self):
        # The 1.0.5-1.0.7 shape: pubspec and changelog still say 1.0.4.
        problems = check("1.0.4+1", ["1.0.4"], tags("1.0.4", "1.0.5"))
        self.assertTrue(any("has no source for that release" in p for p in problems), problems)

    def test_one_commit_cannot_be_several_releases(self):
        problems = check("1.0.7+1", ["1.0.7"], tags("1.0.4", "1.0.5", "1.0.6", "1.0.7", commit="bf01594"))
        self.assertTrue(any("one commit cannot be several releases" in p for p in problems), problems)
        self.assertTrue(any("bf01594" in p for p in problems), problems)

    def test_distinct_commits_are_not_flagged(self):
        problems = check("1.0.7+1", ["1.0.7"], {"1.0.6": "aaa", "1.0.7": "bbb"})
        self.assertEqual(problems, [])

    def test_published_manifest_ahead_of_the_tree(self):
        problems = check("1.0.4+1", ["1.0.4"], tags("1.0.4"), {"version": "1.0.7+10311835", "tag": "v1.0.7"})
        self.assertTrue(any("update.json publishes 1.0.7" in p for p in problems), problems)

    def test_published_manifest_with_unknown_tag(self):
        problems = check("1.0.7+1", ["1.0.7"], tags("1.0.7"), {"version": "1.0.7+1", "tag": "v1.0.9"})
        self.assertTrue(any("v1.0.9" in p for p in problems), problems)

    def test_pubspec_without_build_placeholder(self):
        problems = check("1.0.7", ["1.0.7"], tags("1.0.7"))
        self.assertTrue(any("build placeholder" in p for p in problems), problems)


if __name__ == "__main__":
    unittest.main()
