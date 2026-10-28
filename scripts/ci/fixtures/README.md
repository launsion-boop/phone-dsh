# Checker fixtures

This directory is always excluded from production scans.  The checker
self-test (`selftest.py`) creates its passing and failing git trees in a
temporary directory outside the repository, so the repository never stores a
tree that is meant to violate a rule.
