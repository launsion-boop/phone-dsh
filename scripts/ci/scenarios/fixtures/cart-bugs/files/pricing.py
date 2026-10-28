# SPDX-License-Identifier: MIT
"""Money helpers for the cart."""


def format_money(amount):
    return f"{round(amount, 2):.2f}"


def tax(amount):
    return round(amount * 1.08, 2)
