# SPDX-License-Identifier: MIT
"""Command-line front end for the contacts store."""

import argparse

import search
import store

PATH = "contacts.json"


def main(argv=None):
    parser = argparse.ArgumentParser(prog="contacts")
    sub = parser.add_subparsers(dest="command", required=True)

    add = sub.add_parser("add")
    add.add_argument("name")
    add.add_argument("phone")
    add.add_argument("city")

    sub.add_parser("list")

    find = sub.add_parser("find")
    find.add_argument("--city")
    find.add_argument("--name")

    args = parser.parse_args(argv)
    contacts = store.load(PATH)
    if args.command == "add":
        contacts.append({"name": args.name, "phone": args.phone, "city": args.city})
        store.save(PATH, contacts)
        print("saved")
    elif args.command == "list":
        for contact in contacts:
            print(contact["name"], contact["phone"], contact["city"])
    else:
        for contact in search.find(contacts, city=args.city, name=args.name):
            print(contact["name"], contact["phone"], contact["city"])


if __name__ == "__main__":
    main()
