# SPDX-License-Identifier: MIT
"""Validate rows against the required columns."""

from config import REQUIRED_COLUMNS
from errors import ValidationError


def check_rows(rows):
    for index, row in enumerate(rows, start=1):
        missing = [column for column in REQUIRED_COLUMNS if not row.get(column)]
        if missing:
            raise ValidationError(
                "row %d is missing %s" % (index, ", ".join(missing)))
    return True
