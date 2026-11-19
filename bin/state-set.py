#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# state-set.py - write one key of the state, in the state that survives.
#
# WHY THIS EXISTS: the state of the loop lives in state.json AND, split by
# concept, in state/<grupo>.json (bin/merge-state.sh). state.json is the
# ARTIFACT: it is rebuilt from state/ by the merge. A writer that touches
# state.json directly leaves the two out of sync and the next --check says the
# state is broken.
#
# So: write the concept file, then let the merge rebuild the artifact.
#
# THE CONCEPT IS NOT THE FILE: the manifest (state/manifest.json) says which
# group holds each key: the group "prs" holds the key "open_prs", so the
# file is state/prs.json and the key inside it is "open_prs". Writing
# state/open_prs.json creates a file that the merge does not know about, and
# the entry never reaches the artifact. That is the bug this script exists to
# not have.
#
# The container of a key can be a DICT (the slots: {issue: {...}}) or a LIST
# (the open PRs: [{number: ..., issue: ...}]). Both exist in the real state
# and both are read by the consumers, so the script follows the shape that is
# already there.
#
# USAGE:
#   bash bin/state-set.py <concept> <key> <json value>
#   bash bin/state-set.py --delete <concept> <key>
#
# EXIT CODES:
#   0  the state was written and the artifact rebuilt
#   2  the concept, the key or the value is not usable
# ---------------------------------------------------------------------------
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ORCH = os.environ.get("ORCH_DIR") or os.path.expanduser("~/.local/share/solidcraft-orch")
STATE_DIR = os.path.join(ORCH, "state")
# The merge that rebuilds the artifact lives with the other scripts.
if os.path.exists(os.path.join(HERE, "merge-state.sh")):
    ORCH_BIN = HERE
else:
    ORCH_BIN = os.environ.get("ORCH_BIN") or os.path.join(ORCH, "bin")


def group_of(concept):
    """The file that holds the key: the manifest says which group it is."""
    try:
        with open(os.path.join(STATE_DIR, "manifest.json"), encoding="utf-8") as fh:
            manifest = json.load(fh)
    except (OSError, json.JSONDecodeError):
        return concept
    groups = manifest.get("groups") or {}
    for group, keys in groups.items():
        if concept in (keys or []):
            return group
    # A key that the manifest does not know: it gets a file of its own, and
    # the merge adopts it in the group of the same name (it says so).
    return concept


def read_json(path):
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError) as error:
        print(f"state-set: {path} is not readable: {error}", file=sys.stderr)
        raise SystemExit(2)


def entry_key(entry):
    """The key of an entry of a list: the PR number, or the issue."""
    if not isinstance(entry, dict):
        return None
    for field in ("number", "pr", "issue"):
        value = entry.get(field)
        if isinstance(value, int):
            return str(value)
        if isinstance(value, str) and value:
            return value
    return None


def main():
    args = sys.argv[1:]
    delete = False
    if args and args[0] == "--delete":
        delete = True
        args = args[1:]
    if delete and len(args) != 2:
        print("state-set: usage: state-set.py --delete <concept> <key>", file=sys.stderr)
        return 2
    if not delete and len(args) != 3:
        print("state-set: usage: state-set.py <concept> <key> <json value>", file=sys.stderr)
        return 2
    concept, key = args[0], args[1]
    raw = "" if delete else args[2]

    group = group_of(concept)
    path = os.path.join(STATE_DIR, f"{group}.json")
    data = read_json(path)
    if not isinstance(data, dict):
        print(f"state-set: {path} does not hold an object", file=sys.stderr)
        return 2

    container = data.get(concept)
    if container is None:
        container = {}
    if isinstance(container, list):
        # A LIST of entries: the key is the number of the entry.
        entries = [e for e in container if entry_key(e) != key]
        if not delete:
            try:
                entries.append(json.loads(raw))
            except json.JSONDecodeError as error:
                print(f"state-set: the value is not JSON: {error}", file=sys.stderr)
                return 2
        data[concept] = entries
    else:
        if not isinstance(container, dict):
            container = {}
        if delete:
            container.pop(key, None)
        else:
            try:
                container[key] = json.loads(raw)
            except json.JSONDecodeError as error:
                print(f"state-set: the value is not JSON: {error}", file=sys.stderr)
                return 2
        data[concept] = container
    if delete and key != concept:
        # A key that the merge adopted at the top level of the file (a key
        # that was not in the manifest) lives there, not in the bucket.
        data.pop(key, None)

    os.makedirs(STATE_DIR, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, ensure_ascii=False)
        fh.write("\n")
    # The artifact is rebuilt from the concept files: that is the merge.
    done = subprocess.run(["bash", os.path.join(ORCH_BIN, "merge-state.sh")], capture_output=True, text=True)
    if done.returncode != 0:
        print(done.stdout.strip() or done.stderr.strip(), file=sys.stderr)
        return done.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
