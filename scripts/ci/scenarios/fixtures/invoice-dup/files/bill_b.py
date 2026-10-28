# SPDX-License-Identifier: MIT
"""Billing module B (copy-pasted) with its own late fee."""


def compute_total(items):
    total = 0
    for quantity, unit_price in items:
        total += quantity * unit_price
    return total


def money(amount):
    return "{:,.2f}".format(amount)


def late_feee(amount):
    return money(amount * 0.05)
