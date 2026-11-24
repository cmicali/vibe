"""ready-to-push.py's tests, over a small workflow of their own.

Usage: python3 -I scripts/checks/ready-to-push-test.py   (from the repo root)
"""
import os
import subprocess
import sys
import tempfile

WORKFLOW = """\
name: CI
on:
  pull_request:
env:
  PLAIN: plain
  FROM_GITHUB: ${{ github.sha }}
jobs:
  first:
    runs-on: macos-26
    steps:
      - uses: actions/checkout@v7
        with:
          fetch-depth: 2

      - name: One line
        run: echo "one $PLAIN" >>log

      # A comment between steps.
      - name: A block
        if: ${{ !cancelled() }}
        run: |
          echo block >>log
          echo second line >>log

      - name: Only after a failure
        if: failure()
        run: echo failure >>log

      - id: context
        run: echo "${{ github.sha }}" >>log

  nightly:
    if: github.event_name == 'schedule'
    runs-on: macos-26
    steps:
      - run: echo nightly >>log

  last:
    needs: first
    runs-on: ubuntu-latest
    steps:
      - name: Always
        if: always()
        run: echo always >>log
      - name: Fails
        run: exit 3
      - name: After the failure
        run: echo after >>log
"""

SCRIPT = os.path.abspath(os.path.join("scripts", "checks", "ready-to-push.py"))
failures = 0


def check(name, ok, detail=""):
    global failures
    print(f"{'ok  ' if ok else 'FAIL'} {name}{'' if ok else ': ' + detail}")
    failures += not ok


with tempfile.TemporaryDirectory() as root:
    path = os.path.join(root, "ci.yml")
    with open(path, "w", encoding="utf-8") as f:
        f.write(WORKFLOW)
    env = dict(os.environ)
    env.pop("FROM_GITHUB", None)
    result = subprocess.run([sys.executable, "-I", SCRIPT, path], cwd=root, env=env,
                            capture_output=True, text=True)
    with open(os.path.join(root, "log"), encoding="utf-8") as f:
        log = f.read()
    out = result.stdout + result.stderr
    check("it runs the steps in order, and stops at the first failure",
          log == "one plain\nblock\nsecond line\nalways\n", repr(log))
    check("it exits with the failing step's status", result.returncode == 3, str(result.returncode))
    check("it names the failing step", "last / Fails failed with status 3" in out, out)
    check("it skips an action", "skip first / actions/checkout@v7: a GitHub action" in out, out)
    check("it skips a step that runs only after a failure",
          "skip first / Only after a failure: runs only when failure()" in out, out)
    check("it skips a step that reads GitHub's context",
          "skip first / context: reads GitHub's context" in out, out)
    check("it skips a job for other events",
          "skip job nightly: runs only when github.event_name == 'schedule'" in out, out)
    check("it skips an env value from GitHub", "skip env FROM_GITHUB" in out, out)

    env["FROM_GITHUB"] = "mine"
    result = subprocess.run([sys.executable, "-I", SCRIPT, path, "--dry-run"], cwd=root, env=env,
                            capture_output=True, text=True)
    check("it keeps an env value this shell sets", "env FROM_GITHUB=mine, from this shell" in result.stdout,
          result.stdout)
    check("a dry run runs nothing and passes", result.returncode == 0 and "after" in result.stdout,
          result.stdout + result.stderr)

sys.exit(1 if failures else 0)
