"""
Regression tests for extract_tags() — covers MP3 ID3v2, FLAC Vorbis, M4A iTunes.

The real-world bug this catches: extract_tags() was implemented with
Vorbis-only key lookup (`tags.get('artist')`), which silently returned
None for every MP3 with proper ID3v2 frames (TPE1/TIT2/TALB).
"""
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

from mutagen.id3 import ID3, TPE1, TIT2, TALB

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import lrclib_pipeline as pipeline  # noqa: E402


class _Info:
    def __init__(self, length: float):
        self.length = length


class _Audio:
    def __init__(self, tags, length: float = 210.0):
        self.tags = tags
        self.info = _Info(length)


class TestExtractTagsMP3(unittest.TestCase):
    """MP3 reads must use ID3v2 frame keys, not Vorbis 'artist'/'title'."""

    def _mp3_with_id3(self, artist: str, title: str, album: str) -> _Audio:
        id3 = ID3()
        id3.add(TPE1(encoding=3, text=[artist]))
        id3.add(TIT2(encoding=3, text=[title]))
        id3.add(TALB(encoding=3, text=[album]))
        return _Audio(id3, length=210.0)

    def test_mp3_id3v2_cyrillic_is_read(self):
        """The Афинаж reproducer: MP3 with valid ID3v2 cyrillic must yield non-None tags."""
        audio = self._mp3_with_id3(
            "Аффинаж",
            "Нефть и уголь",
            "Общество с ограниченной ответственностью",
        )
        with patch.object(pipeline, "MutagenFile", return_value=audio):
            info = pipeline.extract_tags(Path("/music/track.mp3"))
        self.assertIsNotNone(
            info,
            "ID3v2 MP3 tags must be readable — currently extract_tags returns None for MP3",
        )
        self.assertEqual(info["artist"], "Аффинаж")
        self.assertEqual(info["title"], "Нефть и уголь")
        self.assertEqual(info["album"], "Общество с ограниченной ответственностью")
        self.assertEqual(info["duration"], 210)

    def test_mp3_latin_id3v2(self):
        audio = self._mp3_with_id3("The Beatles", "Let It Be", "Let It Be")
        with patch.object(pipeline, "MutagenFile", return_value=audio):
            info = pipeline.extract_tags(Path("/music/let-it-be.mp3"))
        self.assertIsNotNone(info)
        self.assertEqual(info["artist"], "The Beatles")
        self.assertEqual(info["title"], "Let It Be")

    def test_mp3_no_tags_returns_none(self):
        """MP3 with truly empty/no tags should still return None (NOTAG)."""
        audio = _Audio(tags=None, length=180.0)
        with patch.object(pipeline, "MutagenFile", return_value=audio):
            info = pipeline.extract_tags(Path("/music/empty.mp3"))
        self.assertIsNone(info)

    def test_mp3_id3_present_but_empty_returns_none(self):
        """Empty ID3 container without TPE1/TIT2 → NOTAG."""
        audio = _Audio(tags=ID3(), length=180.0)
        with patch.object(pipeline, "MutagenFile", return_value=audio):
            info = pipeline.extract_tags(Path("/music/blank.mp3"))
        self.assertIsNone(info)


class TestExtractTagsFLAC(unittest.TestCase):
    """FLAC/Vorbis path must keep working (the format that was already OK)."""

    def test_flac_vorbis_cyrillic(self):
        audio = _Audio(
            tags={"artist": ["Аффинаж"], "title": ["Прыгаю-стою"], "album": ["Русские песни"]},
            length=200.0,
        )
        with patch.object(pipeline, "MutagenFile", return_value=audio):
            info = pipeline.extract_tags(Path("/music/track.flac"))
        self.assertIsNotNone(info)
        self.assertEqual(info["artist"], "Аффинаж")
        self.assertEqual(info["title"], "Прыгаю-стою")

    def test_flac_uppercase_keys(self):
        audio = _Audio(
            tags={"ARTIST": ["Queen"], "TITLE": ["Bohemian Rhapsody"], "ALBUM": ["A Night at the Opera"]},
            length=354.0,
        )
        with patch.object(pipeline, "MutagenFile", return_value=audio):
            info = pipeline.extract_tags(Path("/music/queen.flac"))
        self.assertIsNotNone(info)
        self.assertEqual(info["artist"], "Queen")


class TestExtractTagsM4A(unittest.TestCase):
    """iTunes-style M4A keys (\\xa9ART, \\xa9nam, \\xa9alb)."""

    def test_m4a_itunes_keys(self):
        audio = _Audio(
            tags={"\xa9ART": ["Земфира"], "\xa9nam": ["Малая Медведица"], "\xa9alb": ["14"]},
            length=210.0,
        )
        with patch.object(pipeline, "MutagenFile", return_value=audio):
            info = pipeline.extract_tags(Path("/music/track.m4a"))
        self.assertIsNotNone(info)
        self.assertEqual(info["artist"], "Земфира")
        self.assertEqual(info["title"], "Малая Медведица")


if __name__ == "__main__":
    unittest.main()
