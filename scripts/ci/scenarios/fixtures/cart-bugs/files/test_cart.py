# SPDX-License-Identifier: MIT
import unittest

from cart import Cart
from pricing import format_money


class CartTests(unittest.TestCase):
    def test_empty_total(self):
        self.assertEqual(Cart().total(), 0)

    def test_total_sums_items(self):
        cart = Cart()
        cart.add("tea", 12.5, 2)
        cart.add("book", 30)
        self.assertEqual(cart.total(), 55.0)

    def test_discount_under_threshold(self):
        cart = Cart()
        cart.add("tea", 99)
        self.assertEqual(cart.apply_discount(), 99)

    def test_discount_at_threshold(self):
        cart = Cart()
        cart.add("tea", 100)
        self.assertEqual(cart.apply_discount(), 90)

    def test_format_money_rounds_half_up(self):
        self.assertEqual(format_money(2.675), "2.68")

    def test_format_money_rounds_ties_up(self):
        self.assertEqual(format_money(0.125), "0.13")


if __name__ == "__main__":
    unittest.main()
