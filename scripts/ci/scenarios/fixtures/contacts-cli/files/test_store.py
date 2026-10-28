# SPDX-License-Identifier: MIT
import json
import os
import tempfile
import unittest

import store


class StoreTests(unittest.TestCase):
    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix=".json")
        os.close(handle)
        self.contacts = [{"name": "Ada", "phone": "1", "city": "London"}]
        store.save(self.path, self.contacts)

    def tearDown(self):
        os.unlink(self.path)

    def test_load_returns_list(self):
        self.assertEqual(store.load(self.path), self.contacts)

    def test_save_adds_trailing_newline(self):
        with open(self.path, encoding="utf-8") as handle:
            self.assertTrue(handle.read().endswith("\n"))

    def test_save_is_utf8(self):
        store.save(self.path, [{"name": "García", "phone": "2", "city": "Madrid"}])
        with open(self.path, encoding="utf-8") as handle:
            self.assertEqual(json.load(handle)[0]["name"], "García")

    def test_round_trip_preserves_keys(self):
        loaded = store.load(self.path)
        self.assertEqual(set(loaded[0]), {"name", "phone", "city"})


if __name__ == "__main__":
    unittest.main()
