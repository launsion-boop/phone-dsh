# SPDX-License-Identifier: MIT
"""Reading statistics."""


def summarize(rows):
    total = sum(row["minutes"] for row in rows)
    users = {row["user"] for row in rows}
    titles = {row["title"] for row in rows}
    return {
        "total_minutes": total,
        "users": len(users),
        "titles": len(titles),
        "average_minutes": total / len(users) if users else 0.0,
    }


def top_items(rows, n):
    counts = {}
    for row in rows:
        counts[row["title"]] = counts.get(row["title"], 0) + 1
    ordered = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    return ordered[:n]
