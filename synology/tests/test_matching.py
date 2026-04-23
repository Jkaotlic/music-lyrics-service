"""
Port of YandexMatching.Tests.ps1 — unit tests for track matching helpers.
Run: python -m unittest tests.test_matching
"""
import sys
import os
import unittest

# Allow running from synology/ root without install
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from providers.yandex import (
    _levenshtein,
    _normalize_title,
    _normalize_artist,
    _track_matches,
)


class TestLevenshtein(unittest.TestCase):
    def test_identical_strings(self):
        self.assertEqual(_levenshtein("hello", "hello"), 0)

    def test_empty_left(self):
        self.assertEqual(_levenshtein("", "abc"), 3)

    def test_empty_right(self):
        self.assertEqual(_levenshtein("abc", ""), 3)

    def test_both_empty(self):
        self.assertEqual(_levenshtein("", ""), 0)

    def test_single_substitution(self):
        self.assertEqual(_levenshtein("kitten", "sitten"), 1)

    def test_known_distance(self):
        # kitten -> sitting = 3
        self.assertEqual(_levenshtein("kitten", "sitting"), 3)

    def test_symmetric(self):
        a, b = "zemfira", "zemphira"
        self.assertEqual(_levenshtein(a, b), _levenshtein(b, a))


class TestNormalizeTitle(unittest.TestCase):
    def test_removes_feat_parenthetical(self):
        result = _normalize_title("Rendez-Vous (feat. Someone)")
        self.assertNotIn("feat", result)
        self.assertNotIn("someone", result)

    def test_lowercases(self):
        result = _normalize_title("HURRICANE")
        self.assertEqual(result, "hurricane")

    def test_strips_remastered(self):
        result = _normalize_title("Come Together (Remastered)")
        self.assertNotIn("remaster", result)

    def test_zemfira_no_feat(self):
        # Plain title: no modification except lowercase
        result = _normalize_title("Малая Медведица")
        self.assertIn("медведица", result)

    def test_beatles_plain(self):
        result = _normalize_title("Let It Be")
        self.assertEqual(result, "let it be")


class TestNormalizeArtist(unittest.TestCase):
    def test_lowercases(self):
        # "the " is now stripped to tolerate "Beatles" vs "The Beatles".
        self.assertEqual(_normalize_artist("The Beatles"), "beatles")

    def test_drops_secondary_artist_comma(self):
        result = _normalize_artist("Queen, David Bowie")
        self.assertIn("queen", result)
        self.assertNotIn("bowie", result)

    def test_drops_secondary_artist_ampersand(self):
        result = _normalize_artist("Queen & David Bowie")
        self.assertIn("queen", result)
        self.assertNotIn("bowie", result)

    def test_zemfira_unchanged(self):
        self.assertEqual(_normalize_artist("Земфира"), "земфира")

    def test_whole_string_brackets_preserved(self):
        # Yandex indexes some bands with bracketed names, e.g. "[AMATORY]".
        # A locally-tagged FLAC says "Amatory" - both must normalize to "amatory".
        self.assertEqual(_normalize_artist("[AMATORY]"), "amatory")
        self.assertEqual(_normalize_artist("Amatory"), "amatory")


class TestTrackMatches(unittest.TestCase):
    """Port of matching fixtures from YandexMatching.Tests.ps1."""

    def _make_candidate(self, artist: str, title: str, duration_sec: int) -> dict:
        return {
            "title": title,
            "artists": [{"name": artist}],
            "durationMs": duration_sec * 1000,
        }

    # --- Zemfira fixtures ---

    def test_zemfira_exact_match(self):
        cand = self._make_candidate("Земфира", "Малая Медведица", 210)
        self.assertTrue(_track_matches("Земфира", "Малая Медведица", 210, cand))

    def test_zemfira_duration_tolerance_within(self):
        cand = self._make_candidate("Земфира", "Малая Медведица", 212)
        self.assertTrue(_track_matches("Земфира", "Малая Медведица", 210, cand, duration_tol=3))

    def test_zemfira_duration_tolerance_exceeded(self):
        cand = self._make_candidate("Земфира", "Малая Медведица", 220)
        self.assertFalse(_track_matches("Земфира", "Малая Медведица", 210, cand, duration_tol=3))

    def test_zemfira_artist_lev_within(self):
        # "Zemfira" vs "Zemphira" — distance 1
        cand = self._make_candidate("Zemphira", "Malaya Medveditsa", 210)
        self.assertTrue(_track_matches("Zemfira", "Malaya Medveditsa", 210, cand, lev_max=3))

    def test_zemfira_artist_lev_exceeded(self):
        cand = self._make_candidate("Completelydifferent", "Малая Медведица", 210)
        self.assertFalse(_track_matches("Земфира", "Малая Медведица", 210, cand, lev_max=3))

    # --- Beatles fixtures ---

    def test_beatles_exact(self):
        cand = self._make_candidate("The Beatles", "Let It Be", 243)
        self.assertTrue(_track_matches("The Beatles", "Let It Be", 243, cand))

    def test_beatles_remastered_title(self):
        # Candidate has "Remastered" suffix — normalizer should strip it
        cand = self._make_candidate("The Beatles", "Let It Be (Remastered 2009)", 243)
        self.assertTrue(_track_matches("The Beatles", "Let It Be", 243, cand, lev_max=3))

    def test_beatles_wrong_track(self):
        cand = self._make_candidate("The Beatles", "Hey Jude", 431)
        self.assertFalse(_track_matches("The Beatles", "Let It Be", 243, cand))

    # --- Queen fixtures ---

    def test_queen_feat_stripped(self):
        # Needle has feat, candidate doesn't
        cand = self._make_candidate("Queen", "Under Pressure", 248)
        self.assertTrue(
            _track_matches("Queen", "Under Pressure (feat. David Bowie)", 248, cand, lev_max=3)
        )

    def test_queen_secondary_artist_ignored(self):
        cand = self._make_candidate("Queen", "Bohemian Rhapsody", 354)
        self.assertTrue(_track_matches("Queen, Freddie Mercury", "Bohemian Rhapsody", 354, cand))

    # --- Duration edge cases ---

    def test_no_duration_skip_check(self):
        # duration=-1 means skip duration check
        cand = self._make_candidate("The Beatles", "Let It Be", 999)
        self.assertTrue(_track_matches("The Beatles", "Let It Be", -1, cand))

    def test_zero_duration_candidate(self):
        # candidate with no durationMs
        cand = {"title": "Let It Be", "artists": [{"name": "The Beatles"}]}
        # With needle duration 243 and tol 3 this should fail (cand_dur=0)
        self.assertFalse(_track_matches("The Beatles", "Let It Be", 243, cand, duration_tol=3))

    # --- Regression: cross-alphabet matching (Latin needle, Cyrillic candidate) ---

    def test_latin_needle_matches_cyrillic_candidate(self):
        """Zemfira (Latin tag) must match 'Земфира' (Cyrillic Yandex result).

        Before the transliteration fallback this mismatched on every Russian
        artist whose local tag happened to be in Latin.
        """
        cand = self._make_candidate("Земфира", "Искала", 214)
        self.assertTrue(_track_matches("Zemfira", "Iskala", 214, cand))

    def test_bracketed_band_name(self):
        """'[AMATORY]' on Yandex matches plain 'Amatory' local tag."""
        cand = self._make_candidate("[AMATORY]", "1 %", 216)
        self.assertTrue(_track_matches("Amatory", "1%", 216, cand))

    def test_russian_title_latin_needle(self):
        """Noize MC: English artist, Cyrillic title on Yandex, Latin title in tag."""
        cand = self._make_candidate("Noize MC", "Выдыхай", 193)
        self.assertTrue(_track_matches("Noize MC", "Vydyhai", 193, cand))


if __name__ == "__main__":
    unittest.main()
