# SPDX-License-Identifier: MIT
import unittest

import search

CONTACTS = [
    {"name": "Ada Lovelace", "phone": "1", "city": "London"},
    {"name": "Grace Hopper", "phone": "2", "city": "New York"},
    {"name": "Alan Turing", "phone": "3", "city": "London"},
]


class SearchTests(unittest.TestCase):
    def test_no_filter_returns_all(self):
        self.assertEqual(search.find(CONTACTS), CONTACTS)

    def test_city_filter(self):
        self.assertEqual([c["name"] for c in search.find(CONTACTS, city="London")],
                         ["Ada Lovelace", "Alan Turing"])

    def test_name_filter_is_case_insensitive(self):
        self.assertEqual([c["name"] for c in search.find(CONTACTS, name="grace")],
                         ["Grace Hopper"])

    def test_combined_filters(self):
        self.assertEqual(search.find(CONTACTS, city="London", name="ada"),
                         [CONTACTS[0]])


if __name__ == "__main__":
    unittest.main()
