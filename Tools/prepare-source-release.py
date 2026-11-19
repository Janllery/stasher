#!/usr/bin/env python3
"""Package the reviewed source manifest without local runtime or signing files."""

import hashlib
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import stat
import struct
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'Tools/source-release-files.txt'
TEXT_TYPES = {'.swift', '.m', '.sh', '.command', '.py', '.md', '.txt', '.dat', '.plist', '.entitlements'}
ALLOWED_TYPES = TEXT_TYPES | {'.png', '.icns'}
ROOT_FILES = {'.gitignore', 'LICENSE', 'README.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md', 'build.sh'}
PATTERNS = {
    'private key': rb'-----BEGIN (?:RSA |EC |OPENSSH |DSA |ENCRYPTED )?PRIVATE KEY-----',
    'GitHub token': rb'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b',
    'AWS access id': rb'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b',
    'OpenAI token': rb'\bsk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{24,}\b',
    'Slack token': rb'\bxox[baprs]-[A-Za-z0-9-]{20,}\b',
    'local home path': rb'/' + rb'Users/[^\s/]+/',
    'URL embedded credentials': rb'https?://[^\s/"<>]+:[^\s/"<>]+@',
}


def fail(message):
    raise SystemExit(message)


def check_png(data, name):
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        fail(f'Invalid PNG: {name}')
    allowed = {b'IHDR', b'IDAT', b'IEND', b'pHYs', b'sRGB', b'gAMA', b'cHRM'}
    offset = 8
    last = None
    while offset + 12 <= len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        kind = data[offset + 4:offset + 8]
        if kind not in allowed or offset + size + 12 > len(data):
            fail(f'Unreviewed PNG metadata or invalid chunk: {name}')
        offset += size + 12
        last = kind
        if kind == b'IEND':
            break
    if offset != len(data) or last != b'IEND':
        fail(f'Invalid PNG end: {name}')


def main():
    names = [line.strip() for line in MANIFEST.read_text().splitlines()
             if line.strip() and not line.startswith('#')]
    if len(names) != len(set(names)):
        fail('Duplicate path in source manifest')
    reviewed = []
    for name in names:
        relative = PurePosixPath(name)
        if relative.is_absolute() or '..' in relative.parts or str(relative) != name:
            fail(f'Invalid source path: {name}')
        if relative.parts[0] not in {'Sources', 'Tests', 'Tools', 'Resources', 'docs'} and name not in ROOT_FILES:
            fail(f'Unapproved source location: {name}')
        path = ROOT.joinpath(*relative.parts)
        if any(parent.is_symlink() for parent in [path, *path.parents] if parent != ROOT.parent):
            fail(f'Symbolic link in source path: {name}')
        if not path.is_file() or (path.suffix not in ALLOWED_TYPES and name not in ROOT_FILES):
            fail(f'Missing file or unapproved file type: {name}')
        data = path.read_bytes()
        for rule, pattern in PATTERNS.items():
            match = re.search(pattern, data)
            if match:
                line = data[:match.start()].count(b'\n') + 1
                fail(f'Potential private content: {name}:{line} ({rule}). Value not displayed.')
        if path.suffix == '.png':
            check_png(data, name)
        reviewed.append((name, path, data))

    info = plistlib.loads((ROOT / 'Resources/Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if not re.fullmatch(r'\d+(?:\.\d+)+', version):
        fail('Invalid app version')
    prefix = f'Stasher-{version}'
    output = ROOT / 'dist' / f'{prefix}-source.zip'
    output.parent.mkdir(exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix='.source-release-', suffix='.tmp', dir=output.parent)
    os.close(descriptor)
    try:
        with zipfile.ZipFile(temporary, 'w', compression=zipfile.ZIP_DEFLATED) as archive:
            checksums = []
            for name, path, data in reviewed:
                entry = zipfile.ZipInfo(f'{prefix}/{name}')
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.create_system = 3
                mode = 0o755 if path.stat().st_mode & stat.S_IXUSR else 0o644
                entry.external_attr = (stat.S_IFREG | mode) << 16
                archive.writestr(entry, data)
                checksums.append(f'{hashlib.sha256(data).hexdigest()}  {name}')
            archive.writestr(f'{prefix}/SOURCE-MANIFEST.sha256', '\n'.join(checksums) + '\n')
        os.replace(temporary, output)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(f'Packaged {len(reviewed)} reviewed source files plus a SHA-256 manifest.')
    print(f'Archive: {output.relative_to(ROOT)}')
    print(f'Archive SHA-256: {hashlib.sha256(output.read_bytes()).hexdigest()}')
    print('Local runtime data, signing identity, app bundles and Git metadata are excluded.')


if __name__ == '__main__':
    main()
