# SPDX-License-Identifier: MIT
import unittest

import pantry
import recipes
import report

RECIPES = [
    {"title": "Garlic Pasta", "ingredients": ["pasta", "garlic", "olive oil"]},
    {"title": "Tomato Soup", "ingredients": ["tomato", "onion", "stock"]},
    {"title": "Banana Bread", "ingredients": ["banana", "flour", "sugar"]},
    {"title": "Cucumber Salad", "ingredients": ["cucumber", "yogurt", "mint"]},
]


def data():
    return {"recipes": RECIPES, "ingredients": pantry.load_pantry("data/pantry.json")}


class RecipeTests(unittest.TestCase):
    def test_load_recipes(self):
        self.assertEqual(len(recipes.load_recipes("data/recipes.json")), 8)

    def test_search_by_title(self):
        self.assertEqual([r["title"] for r in recipes.search(data(), "banana")],
                         ["Banana Bread"])

    def test_search_is_alphabetical(self):
        matches = recipes.search(data(), "o")
        self.assertEqual([r["title"] for r in matches],
                         sorted(r["title"] for r in matches))

    def test_search_matches_ingredient(self):
        self.assertEqual([r["title"] for r in recipes.search(data(), "yogurt")],
                         ["Cucumber Salad"])

    def test_report_has_title_and_items(self):
        text = report.to_markdown(recipes.search(data(), "garlic"))
        self.assertIn("Garlic Pasta", text)
        self.assertTrue(text.startswith("# Recipes"))


if __name__ == "__main__":
    unittest.main()
