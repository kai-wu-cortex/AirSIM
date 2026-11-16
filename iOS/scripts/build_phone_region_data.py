#!/usr/bin/env python3
"""Convert an Apache-2.0 libphonenumber zh/86.txt snapshot into ASREG001.

No network access. Use --revision with the upstream commit and supply its LICENSE.
Output is the read-only resource used by PhoneRegionLookup in PhoneViews.swift.
"""
import argparse
import hashlib
import json
import shutil
import struct
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
parser.add_argument('--license', type=Path, required=True)
parser.add_argument('--revision', required=True)
parser.add_argument('--output', type=Path, default=Path(__file__).resolve().parents[1] / 'AirSIM/PhoneRegionResources')
parser.add_argument('--mobile-source', type=Path)
parser.add_argument('--mobile-readme', type=Path)
parser.add_argument('--mobile-revision')
args = parser.parse_args()
text = args.source.read_text(encoding='utf-8-sig')
pairs = {}
for line in text.splitlines():
    if line and not line.startswith('#'):
        prefix, region = line.split('|', 1)
        assert prefix.isascii() and prefix.isdigit() and prefix.startswith('86')
        pairs[int(prefix)] = region.strip()
args.output.mkdir(parents=True, exist_ok=True)
mobile_metadata = None
if args.mobile_source:
    assert args.mobile_readme and args.mobile_revision
    mobile = args.mobile_source.read_bytes()
    offset = struct.unpack_from('<I', mobile, 4)[0]
    assert offset >= 8 and (len(mobile) - offset) % 9 == 0
    added = 0
    for position in range(offset, len(mobile), 9):
        prefix, label_offset, carrier = struct.unpack_from('<IIB', mobile, position)
        province, city, *_ = mobile[label_offset:mobile.index(b'\0', label_offset)].decode('utf-8').split('|')
        # Retain the original Google regions when it already covers this prefix.
        e164 = '86' + str(prefix)
        if any(int(e164[:length]) in pairs for length in range(4, len(e164) + 1)):
            continue
        name = (province + '市') if province in ['北京', '上海', '天津', '重庆'] else province + ' ' + city
        pairs[int(e164)] = name
        added += 1
    shutil.copyfile(args.mobile_readme, args.output / 'PhoneRegion-Mobile-README.md')
    mobile_metadata = {'repository': 'https://github.com/ls0f/phone', 'revision': args.mobile_revision,
                       'sha256': hashlib.sha256(mobile).hexdigest(), 'added_prefixes': added,
                       'license': 'MIT (declared in bundled upstream README)', 'snapshot': mobile[:4].decode('ascii')}
regions = sorted(set(pairs.values()))
assert 0 < len(pairs) <= 800_000 and 0 < len(regions) < 10_000
indices = {name: index for index, name in enumerate(regions)}
data = bytearray(b'ASREG001') + struct.pack('<II', len(pairs), len(regions))
for name in regions:
    encoded = name.encode('utf-8')
    data += struct.pack('<H', len(encoded)) + encoded
for prefix, region in sorted(pairs.items()):
    data += struct.pack('<QH', prefix, indices[region])
args.output.mkdir(parents=True, exist_ok=True)
(args.output / 'PhoneRegionCN.dat').write_bytes(data)
shutil.copyfile(args.license, args.output / 'PhoneRegion-LICENSE.txt')
notice = ('Phone region data derived from Google libphonenumber.\n'
          f'Source revision: {args.revision}\n'
          f'Source: https://github.com/google/libphonenumber/blob/{args.revision}/resources/geocoding/zh/86.txt\n'
          'Copyright (C) 2011 The Libphonenumber Authors\n'
          'Licensed under the Apache License, Version 2.0; see PhoneRegion-LICENSE.txt.\n'
          'Changes: text prefixes converted into a sorted binary lookup table; missing mobile prefixes supplemented as recorded in PhoneRegion-source.json.\n\n'
          + '\n'.join(line for line in text.splitlines() if line.startswith('#')) + '\n')
(args.output / 'PhoneRegion-NOTICE.txt').write_text(notice, encoding='utf-8')
(args.output / 'PhoneRegion-source.json').write_text(json.dumps({
    'revision': args.revision, 'mobile_supplement': mobile_metadata,
    'source_sha256': hashlib.sha256(args.source.read_bytes()).hexdigest(),
    'records': len(pairs), 'regions': len(regions),
    'format': 'ASREG001, little-endian UInt64 prefix/UInt16 region index'
}, indent=2) + '\n', encoding='utf-8')
print(f'{len(pairs)} prefixes, {len(regions)} regions, {len(data)} bytes')
