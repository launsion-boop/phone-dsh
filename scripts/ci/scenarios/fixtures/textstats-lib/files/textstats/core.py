# SPDX-License-Identifier: MIT
"""Word counting and ranking."""

import string


def _tokenize(text):
    words = text.lower().split()
    return [word.strip(string.punctuation) for word in words if word.strip(string.punctuation)]


def count_words(text):
    counts = {}
    for word in _tokenize(text):
        counts[word] = counts.get(word, 0) + 1
    return counts


def top_words(text, n):
    counts = count_words(text)
    ordered = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return ordered[:n]
