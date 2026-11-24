"""The commit-msg hook's tests: each case is a commit message and whether
.githooks/commit-msg must accept it.

Usage: python3 -I scripts/checks/commit-msg-test.py   (from the repo root)
"""
import subprocess
import sys
import tempfile

CASES = [
    ("a plain message passes", "audio: Fade the voice out\n\nThe fade is linear.\n", True),
    ("prose that says generated passes", "audio: Fade\n\nThe table is generated with the script.\n", True),
    ("a commented trailer passes", "audio: Fade\n\n# Co-Authored-By: A Tool <x@example.com>\n", True),
    ("a Co-Authored-By trailer fails", "audio: Fade\n\nCo-Authored-By: A Tool <x@example.com>\n", False),
    ("a lowercase trailer fails", "audio: Fade\n\nco-authored-by: A Tool <x@example.com>\n", False),
    ("a Generated with line fails", "audio: Fade\n\nGenerated with A Tool\n", False),
    ("an emoji Generated with line fails", "audio: Fade\n\n\U0001f916 GENERATED WITH [A Tool](https://example.com)\n", False),
]

failures = 0
for name, message, accepted in CASES:
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt") as f:
        f.write(message)
        f.flush()
        result = subprocess.run(["sh", ".githooks/commit-msg", f.name], capture_output=True, text=True)
    if (result.returncode == 0) != accepted or (not accepted and "commit-msg:" not in result.stderr):
        failures += 1
        print(f"FAIL {name}: status {result.returncode}, {result.stderr!r}")
    else:
        print(f"ok   {name}")

sys.exit(1 if failures else 0)
