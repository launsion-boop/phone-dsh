# SPDX-License-Identifier: MIT
"""Shopping cart with a fixed full-reduction discount."""


class Cart:
    """A cart of priced line items."""

    def __init__(self):
        self.items = []

    def add(self, name, price, quantity=1):
        self.items.append({"name": name, "price": price, "quantity": quantity})

    def total(self):
        return sum(item["price"] * item["quantity"] for item in self.items)

    def apply_discount(self):
        total = self.total()
        if total > 100:
            return total - 10
        return total
