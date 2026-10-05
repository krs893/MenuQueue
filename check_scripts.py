#!/usr/bin/env python3
"""Extracts every AppleScript literal from Sources/*.swift and syntax-checks
it with osacompile. Music.app's dictionary steals plain identifiers like `st`,
so this catches clashes without having to launch Music."""
import re, subprocess, tempfile, os, sys, textwrap

import glob
src = "\n".join(open(f).read() for f in sorted(glob.glob('Sources/*.swift')))

handler = re.search(r'private static let joinHandler = """\n(.*?)\n    """', src, re.S).group(1)
handler = textwrap.dedent(handler)

# A closing delimiter may sit at any depth: literals are indented to match the
# code around them, and a fragment passed as an argument sits deeper.
blocks = re.findall(r'"""\n(.*?)\n[ \t]*"""', src, re.S)
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
    if r.returncode != 0:
        # Some literals are fragments spliced into a Music `tell` block at run
        # time; outside one, Music's terms such as `database ID` mean nothing.
        # Accept a fragment if it compiles in the context it is used in.
        wrapped = 'tell application id "com.apple.Music"\n' + full + '\nend tell\n'
        with open(path, 'w') as f:
            f.write(wrapped)
        r2 = subprocess.run(['osacompile', '-o', '/dev/null', path],
                            capture_output=True, text=True)
        if r2.returncode == 0:
            r = r2
    label = body.strip().splitlines()[0][:60]
    if r.returncode == 0:
        print(f"  OK   [{i}] {label}")
    else:
        ok = False
        print(f"  FAIL [{i}] {label}\n       {r.stderr.strip()}")
    os.unlink(path)

sys.exit(0 if ok else 1)
