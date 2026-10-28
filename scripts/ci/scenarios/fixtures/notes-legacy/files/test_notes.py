# SPDX-License-Identifier: MIT
import json
import os
import tempfile
import unittest

import cli
import format
import notes
import storage


class NoteTests(unittest.TestCase):
    def test_new_note_trims_title(self):
        note = notes.new_note("  Groceries  ", "milk")
        self.assertEqual(note.title, "Groceries")

    def test_save_and_load_round_trip(self):
        handle, path = tempfile.mkstemp(suffix=".json")
        os.close(handle)
        try:
            storage.save(path, [{"title": "a", "body": "b", "created": ""}])
            self.assertEqual(storage.load(path)[0]["title"], "a")
        finally:
            os.unlink(path)

    def test_find_matches_title_slug(self):
        notes_list = [{"title": "Deep Work", "body": "focus", "created": ""}]
        self.assertEqual(storage.find(notes_list, "deep work"), notes_list)

    def test_preview_truncates(self):
        self.assertTrue(storage.preview({"body": "x" * 100}, 10).endswith("\u2026"))

    def test_wrap_respects_width(self):
        lines = format.wrap("alpha beta gamma delta", 11)
        self.assertTrue(all(len(line) <= 11 for line in lines))

    def test_render_contains_title_and_tags(self):
        text = cli.render({"title": "Plan", "body": "one two", "created": "",
                           "tags": ["work"]}, 20)
        self.assertIn("Plan", text)
        self.assertIn("tags: work", text)


if __name__ == "__main__":
    unittest.main()
