# SPDX-License-Identifier: MIT
"""Pipeline errors."""


class ValidationError(Exception):
    """A row or table does not satisfy the schema."""
