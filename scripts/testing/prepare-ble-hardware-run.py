#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Inject a private live fixture config into a built hardware xctestrun.
Xcode normalizes environment values as paths, collapsing http:// to http:/;
pass only the authority and construct the URL inside the test process.
"""
import argparse
import ipaddress
from pathlib import Path
import plistlib

parser = argparse.ArgumentParser()
parser.add_argument('--xctestrun', type=Path, required=True)
parser.add_argument('--authority', required=True)
parser.add_argument('--token-file', type=Path, required=True)
parser.add_argument('--output', type=Path, required=True)
args = parser.parse_args()
host, port = args.authority.rsplit(':', 1)
assert ipaddress.IPv4Address(host).is_private and 0 < int(port) <= 65535
assert args.xctestrun.parent.resolve() == args.output.parent.resolve(), 'Keep test bundle relative paths unchanged'
value = plistlib.loads(args.xctestrun.read_bytes())
target = value['PhoneDSHBLEHardwareTests']
env = {'PDSH_BLE_FIXTURE_AUTHORITY': args.authority, 'PDSH_BLE_FIXTURE_TOKEN': args.token_file.read_text().strip()}
for key in ['EnvironmentVariables', 'TestingEnvironmentVariables']:
    target.setdefault(key, {}).pop('PDSH_BLE_FIXTURE_ORIGIN', None)
    target[key].update(env)
args.output.write_bytes(plistlib.dumps(value))
args.output.chmod(0o600)
print('Prepared live hardware xctestrun; fixture token is not displayed.')
