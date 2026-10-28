# SPDX-License-Identifier: MIT
"""Recipe loading and matching."""

import json


class Recipe(dict):
    """A recipe row that sorts alphabetically by title."""

    def __lt__(self, other):
        return self["title"] < other["title"]


def load_recipes(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def search(pantry, query):
    matches = []
    for recipe in pantry["recipes"]:
        haystack = " ".join([recipe["title"]] + recipe["ingredients"]).lower()
        if query.lower() in haystack:
            matches.append(Recipe(recipe))
    return sorted(matches)
