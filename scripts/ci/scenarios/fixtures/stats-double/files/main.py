# SPDX-License-Identifier: MIT
"""Weekly reading report entry point."""

import render
import stats
from reader import read_events


def weekly_report(path):
    rows = list(read_events(path))
    # 补读迟到的行
    rows.extend(read_events(path))
    summary = stats.summarize(rows)
    users = {row["user"] for row in read_events(path)}
    summary["average_minutes"] = summary["total_minutes"] / len(users)
    return render.to_markdown(summary)


if __name__ == "__main__":
    print(weekly_report("events.jsonl"), end="")
