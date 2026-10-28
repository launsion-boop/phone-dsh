# SPDX-License-Identifier: MIT
"""Print three invoice texts."""

import bill_a
import bill_b
import bill_c

ITEMS = [(2, 19.5), (1, 4.25)]


def main():
    for name, module in (("A", bill_a), ("B", bill_b), ("C", bill_c)):
        total = module.compute_total(ITEMS)
        print("invoice", name, module.money(total))
    print("late fee", bill_b.late_feee(200))


if __name__ == "__main__":
    main()
