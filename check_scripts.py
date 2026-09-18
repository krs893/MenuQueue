#!/usr/bin/env python3
"""Extracts every AppleScript literal from MusicBridge.swift and syntax-checks
it with osacompile. Music.app's dictionary steals plain identifiers like `st`,
so this catches clashes without having to launch Music."""
import re, subprocess, tempfile, os, sys, textwrap

src = open('Sources/MusicBridge.swift').read()

handler = re.search(r'private static let joinHandler = """\n(.*?)\n    """', src, re.S).group(1)
handler = textwrap.dedent(handler)

blocks = re.findall(r'"""\n(.*?)\n(?:        |    )"""', src, re.S)
ok = True
for i, b in enumerate(blocks):
    body = textwrap.dedent(b)
    if 'on joinList' in body:
        continue
    # Replace Swift interpolations with literals of a plausible shape.
    body = re.sub(r'\\\(limit\)', '50', body)
    body = re.sub(r'\\\(databaseID\)', '123', body)
    body = re.sub(r'\\\((?:q|pid)\)', 'X', body)
    body = re.sub(r'\\\([^)]*\)', 'X', body)
    full = (handler + "\n\n" + body) if 'my join' in body else body
    with tempfile.NamedTemporaryFile('w', suffix='.applescript', delete=False) as f:
        f.write(full); path = f.name
    r = subprocess.run(['osacompile', '-o', '/dev/null', path],
                       capture_output=True, text=True)
    label = body.strip().splitlines()[0][:60]
    if r.returncode == 0:
        print(f"  OK   [{i}] {label}")
    else:
        ok = False
        print(f"  FAIL [{i}] {label}\n       {r.stderr.strip()}")
    os.unlink(path)

sys.exit(0 if ok else 1)
