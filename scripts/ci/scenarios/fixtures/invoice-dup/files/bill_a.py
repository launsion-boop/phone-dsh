# SPDX-License-Identifier: MIT
"""Billing module A (copy-pasted)."""


def compute_total(items):
    total = 0
    for quantity, unit_price in items:
        total += quantity * unit_price
    return total


def money(amount):
    return "{:,.2f}".format(amount)
