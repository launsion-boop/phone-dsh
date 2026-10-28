# SPDX-License-Identifier: MIT
"""Filter contacts by city or name substring."""


def find(contacts, city=None, name=None):
    matches = []
    for contact in contacts:
        if city is not None and city.lower() not in contact["city"].lower():
            continue
        if name is not None and name.lower() not in contact["name"].lower():
            continue
        matches.append(contact)
    return matches
