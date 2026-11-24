"""Runs here, in order, every step a GitHub workflow runs on a pull request.

It reads the steps from the workflow file, so the list can't drift from CI's.
It runs each job in the file's order and each step's run text in bash, as
GitHub does. It skips, with one line each:
- a job whose condition names events other than a pull request;
- a step that uses an action (checkout, caches, uploads);
- a step whose condition is anything but always() or !cancelled(), such as
  one that runs only after a failure;
- a step that reads GitHub's context through ${{ }}.
A workflow env value that reads GitHub's context is set only when this shell
sets it. It stops at the first failing step, names it, and exits with its status.

Usage: python3 -I scripts/checks/ready-to-push.py WORKFLOW [--dry-run]
"""
import os
import re
import subprocess
import sys
import time

RUN_ALWAYS = {"always()", "!cancelled()"}


def indent(line):
    return len(line) - len(line.lstrip(" "))


def condition(value):
    value = value.strip()
    match = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", value)
    return match.group(1) if match else value


def unquote(value):
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
        return value[1:-1]
    return value


def block(lines, start, key_indent):
    """The lines of a block scalar after lines[start], dedented, and the next index."""
    body, i = [], start + 1
    while i < len(lines) and (not lines[i].strip() or indent(lines[i]) > key_indent):
        body.append(lines[i])
        i += 1
    while body and not body[-1].strip():
        body.pop()
    cut = min((indent(l) for l in body if l.strip()), default=0)
    return "\n".join(l[cut:] for l in body), i


def parse(text):
    """The workflow's env names and values, and its jobs as (name, if, steps).

    It reads only the shape GitHub's workflows here use: two-space indents,
    steps as a list, and run as one line or a | block.
    """
    lines = text.splitlines()
    env, jobs, section, i = {}, [], None, 0
    while i < len(lines):
        line = lines[i]
        if not line.strip() or line.lstrip().startswith("#"):
            i += 1
            continue
        level = indent(line)
        if level == 0:
            section = line.split(":")[0]
        elif section == "env" and level == 2:
            name, _, value = line.strip().partition(":")
            env[name] = unquote(value)
        elif section == "jobs" and level == 2:
            jobs.append({"name": line.strip().rstrip(":"), "if": "", "steps": [], "in_steps": False})
        elif section == "jobs" and jobs and level == 4:
            key, _, value = line.strip().partition(":")
            if key == "if":
                jobs[-1]["if"] = condition(value)
            jobs[-1]["in_steps"] = key == "steps"
        elif section == "jobs" and jobs and jobs[-1]["in_steps"] and line.lstrip().startswith("- "):
            # The dash line's text is the step's first key.
            key_indent = level + 2
            lines[i] = " " * key_indent + line.lstrip()[2:]
            step = {"raw": ""}
            jobs[-1]["steps"].append(step)
            while i < len(lines) and (not lines[i].strip() or indent(lines[i]) >= key_indent):
                line = lines[i]
                key, _, value = line.strip().partition(":")
                is_key = indent(line) == key_indent
                if is_key and key == "run" and value.strip().startswith("|"):
                    step["run"], i = block(lines, i, key_indent)
                    step["raw"] += step["run"] + "\n"
                    continue
                if is_key and key in ("name", "id", "uses", "if", "run"):
                    step[key] = unquote(value)
                if not (is_key and key == "if"):
                    step["raw"] += line + "\n"
                i += 1
            continue
        i += 1
    return env, jobs


def label(job, step):
    return f"{job['name']} / {step.get('name') or step.get('id') or step.get('uses') or step.get('run')}"


def skip_reason(step):
    if "uses" in step:
        return "a GitHub action"
    if step.get("if") and condition(step["if"]) not in RUN_ALWAYS:
        return f"runs only when {condition(step['if'])}"
    if "${{" in step["raw"]:
        return "reads GitHub's context"
    if "run" not in step:
        return "nothing to run"
    return None


def main(argv):
    if len(argv) not in (2, 3) or argv[2:] not in ([], ["--dry-run"]):
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    dry_run = argv[2:] == ["--dry-run"]
    sys.stdout.reconfigure(line_buffering=True)
    with open(argv[1], encoding="utf-8") as f:
        env, jobs = parse(f.read())
    for name, value in env.items():
        if "${{" not in value:
            os.environ[name] = value
        elif name in os.environ:
            print(f"env {name}={os.environ[name]}, from this shell")
        else:
            print(f"skip env {name}: reads GitHub's context")
    began = time.monotonic()
    for job in jobs:
        if "github.event_name" in job["if"] and "pull_request" not in job["if"]:
            print(f"skip job {job['name']}: runs only when {job['if']}")
            continue
        for step in job["steps"]:
            reason = skip_reason(step)
            if reason:
                print(f"skip {label(job, step)}: {reason}")
                continue
            print(f"==> {label(job, step)}")
            if dry_run:
                print(step["run"])
                continue
            start = time.monotonic()
            status = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", step["run"]]).returncode
            if status:
                print(f"ready-to-push: {label(job, step)} failed with status {status}", file=sys.stderr)
                return status
            print(f"    passed in {time.monotonic() - start:.0f} s")
    if not dry_run:
        print(f"ready-to-push: every step passed in {time.monotonic() - began:.0f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
