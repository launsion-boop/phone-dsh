# SPDX-License-Identifier: MIT
"""Write a small Markdown report."""


def write_report(path, rows):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("# Contacts\n\n")
        handle.write("| name | email |\n")
        handle.write("| --- | --- |\n")
        for row in rows:
            handle.write("| %s | %s |\n" % (row["name"], row["email"]))
