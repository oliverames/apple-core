#!/usr/bin/env python3
"""Bundle exact license records from pinned dependency revisions and donor files."""
import argparse
import json
import pathlib
import re
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('checkouts', nargs='+', type=pathlib.Path)
parser.add_argument('--check', action='store_true', help='Fail if the bundled notices are stale')
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[1]
pins = json.loads((root / 'Apple Core.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved').read_text())['pins']
parts = ['Apple Core: Third-Party License Notices\n\nThese notices preserve the licenses supplied by source donors and pinned\ndependencies. Some distribution variants omit individual components.\nThey do not replace the license applicable to Apple Core itself.\n']
donors = sorted((root / 'THIRD_PARTY_LICENSES').glob('*.LICENSE'))
for path in donors:
    parts.append(f'\n{"=" * 72}\nSource donor: {path.stem}\n\n{path.read_text().strip()}\n')
for pin in sorted(pins, key=lambda p: p['identity']):
    identity, revision = pin['identity'], pin['state']['revision']
    candidates = [p for base in args.checkouts for p in base.iterdir()
                  if p.is_dir() and p.name.lower() == identity.lower()]
    checkout = next((p for p in candidates if subprocess.run(
        ['git', '-C', str(p), 'cat-file', '-e', revision], capture_output=True).returncode == 0), None)
    if checkout is None:
        raise SystemExit(f'Missing pinned source checkout: {identity} {revision}')
    paths = subprocess.check_output(['git', '-C', str(checkout), 'ls-tree', '-r', '--name-only', revision], text=True).splitlines()
    licenses = [p for p in paths if re.fullmatch(r'(LICENSE|LICENCE|NOTICE|COPYING)(\..*)?', pathlib.PurePosixPath(p).name, re.I)]
    if not any(pathlib.PurePosixPath(p).parent == pathlib.PurePosixPath('.') for p in licenses):
        raise SystemExit(f'Missing root license record: {identity}')
    parts.append(f'\n{"=" * 72}\nDependency: {identity}\nSource: {pin["location"]}\nRevision: {revision}\n')
    for path in sorted(licenses):
        content = subprocess.check_output(['git', '-C', str(checkout), 'show', f'{revision}:{path}']).decode('utf-8')
        parts.append(f'\n--- {path} ---\n\n{content.strip()}\n')
output = root / 'App/Resources/ThirdPartyNotices.txt'
content = '\n'.join(parts)
if args.check:
    if not output.exists() or output.read_text() != content:
        raise SystemExit('Bundled third-party notices are missing or stale')
else:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content)
print(f'Verified notices for {len(pins)} pinned dependencies and {len(donors)} source donors.')
