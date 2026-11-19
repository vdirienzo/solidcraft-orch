#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# slot-prs.py - the pull requests of ours, matched to the slots in flight.
#
# WHY THIS EXISTS (19-11-2026): the wave has to know, for every slot, whether
# its work landed as a pull request. Asking GitHub once per slot is slow (one
# call each), and the branch of a slot is not always "fix-<issue>": the
# agents of the last waves used "fix/<issue>-something". So the PRs are
# fetched ONCE and matched here, by the branch and by the issue number.
#
# The output is one line per slot: "<issue>\t<pr>\t<branch>\t<ours>".
# A slot without a PR gets an empty "<pr>". The fourth field says who owns
# the PR: "ours" or "other" (the claim was lost and somebody else's PR is
# the one that mentions the issue).
#
# USAGE:
#   python3 bin/slot-prs.py <slots.json> <prs.json> [our login]
# ---------------------------------------------------------------------------
import json
import re
import sys


def mentions(text, issue):
    """Does the text mention the issue as #<issue> (and not #<issue>0)?"""
    if not text:
        return False
    return re.search(r"#%d(?![0-9])" % issue, text) is not None


def main():
    if len(sys.argv) < 3:
        print("slot-prs: usage: slot-prs.py <slots.json> <prs.json> [login]", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            slots = json.load(fh)
    except (OSError, json.JSONDecodeError) as error:
        print(f"slot-prs: los slots no se pudieron leer: {error}", file=sys.stderr)
        return 2
    try:
        with open(sys.argv[2], encoding="utf-8") as fh:
            prs = json.load(fh)
    except (OSError, json.JSONDecodeError) as error:
        print(f"slot-prs: los PRs no se pudieron leer: {error}", file=sys.stderr)
        return 2
    ours_login = sys.argv[3] if len(sys.argv) > 3 else ""

    for slot in slots:
        issue = int(slot["issue"])
        branch = slot.get("branch") or ""
        found = None
        other = None
        for pr in prs:
            if not isinstance(pr, dict):
                continue
            author = (pr.get("author") or {}).get("login") or ""
            body = pr.get("body") or ""
            title = pr.get("title") or ""
            head = pr.get("headRefName") or ""
            mine = bool(ours_login) and author == ours_login
            by_branch = bool(branch) and head == branch
            by_issue = mentions(body, issue) or mentions(title, issue)
            if not (by_branch or by_issue):
                continue
            if mine:
                # Our PR: the one of OUR branch wins over the one that only
                # mentions the issue (a PR of ours can mention another issue).
                if found is None or by_branch:
                    found = pr
            elif other is None:
                other = pr
        if found is not None:
            print(f"{issue}\t{found.get('number')}\t{found.get('headRefName') or ''}\tours")
        elif other is not None:
            print(f"{issue}\t{other.get('number')}\t{other.get('headRefName') or ''}\tother")
        else:
            print(f"{issue}\t\t\t")
    return 0


if __name__ == "__main__":
    sys.exit(main())
