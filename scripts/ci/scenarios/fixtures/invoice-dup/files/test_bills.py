# SPDX-License-Identifier: MIT
import unittest

import bill_a
import bill_b
import bill_c

ITEMS = [(2, 10.0), (3, 1.5)]


class BillingTests(unittest.TestCase):
    def test_a_total(self):
        self.assertEqual(bill_a.compute_total(ITEMS), 24.5)

    def test_b_total(self):
        self.assertEqual(bill_b.compute_total(ITEMS), 24.5)

    def test_c_total(self):
        self.assertEqual(bill_c.compute_total(ITEMS), 24.5)

    def test_a_money(self):
        self.assertEqual(bill_a.money(1234.5), "1,234.50")

    def test_b_money(self):
        self.assertEqual(bill_b.money(0), "0.00")

    def test_c_money(self):
        self.assertEqual(bill_c.money(99.999), "100.00")

    def test_empty_total(self):
        self.assertEqual(bill_a.compute_total([]), 0)

    def test_b_late_fee(self):
        self.assertEqual(bill_b.late_feee(200), "10.00")


if __name__ == "__main__":
    unittest.main()
