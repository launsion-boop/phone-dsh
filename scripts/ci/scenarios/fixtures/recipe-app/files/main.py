# SPDX-License-Identifier: MIT
"""Recipe recommender entry point."""

import argparse

import pantry
import recipes
import report


def main(argv=None):
    parser = argparse.ArgumentParser(prog="recipe-app")
    parser.add_argument("query")
    args = parser.parse_args(argv)
    pantry_data = pantry.load_pantry("data/pantry.json")
    pantry_data["recipes"] = recipes.load_recipes("data/recipes.json")
    matches = recipes.search(pantry_data, args.query)
    print(report.to_markdown(matches), end="")


if __name__ == "__main__":
    main()
