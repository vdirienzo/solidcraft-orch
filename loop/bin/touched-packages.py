#!/usr/bin/env python3
"""The packages whose directory holds a changed file.

Usage: touched-packages.py --paths FILE --metadata FILE

FILE holds the changed paths relative to the root of the repository, separated
by NUL (that is what `git diff -z` writes). --metadata is the output of
`cargo metadata --no-deps --format-version 1`: the file the gate already
reads for scripts/ci/affected.py.

Prints:
  packages=a b c     the packages whose directory holds a changed file
  narrow=true|false  whether the tests can be narrowed to those packages

The criterion is the one of scripts/ci/affected.py of the repository: a file
belongs to the package whose directory holds it, and the LONGEST directory
that is a prefix of the path wins. The DEPENDENTS of that package are not
here: this is the scope of the TESTS, not the scope of the COMPILATION (the
clippy and the check of the workspace keep the whole scope, so a dependent
that does not compile is still red).

`narrow` is false when a changed file belongs to no package (a file of the
root of the repository, a test data folder, a vendored crate): the tests
then run on the whole scope. A narrower run is an optimization; a wrong
narrower run is a green that hides a red, so the doubt is always the whole
scope.
"""
import argparse
import json
import sys

# The files that belong to no package and change no code: they mirror the
# list of scripts/ci/affected.py of the repository, so that a change that
# also touches a document does not stop the narrowing of the tests.
IGNORED_PREFIXES = ("docs/", "packaging/", ".github/", "scripts/claim/",
                     "scripts/triage/")
IGNORED_FILES = ("vendor/README.md",)


def read_paths(src):
    """The changed paths: a NUL separated file, as `git diff -z` writes it."""
    with open(src, "rb") as handle:
        data = handle.read()
    return [p.decode("utf-8", "replace") for p in data.split(b"\0") if p]


def package_dirs(meta):
    """The directory of every package, relative to the root of the workspace.

    The directory of the package of the root of the workspace is the empty
    string: it is the prefix of every path.
    """
    root = meta["workspace_root"].replace("\\", "/").rstrip("/") + "/"
    out = {}
    for package in meta["packages"]:
        manifest = package["manifest_path"].replace("\\", "/")
        if not manifest.startswith(root):
            continue
        relative = manifest[len(root):]
        directory = relative.rsplit("/", 1)[0] if "/" in relative else ""
        out[directory + "/" if directory else ""] = package["name"]
    return out


def is_ignored(path):
    """True when the path changes no code (documentation, packaging, CI)."""
    if path in IGNORED_FILES:
        return True
    if path.startswith(IGNORED_PREFIXES):
        return True
    if "/" not in path and path.endswith(".md"):
        return True
    return False


def select(meta, paths):
    """Return (narrow, sorted package names)."""
    by_dir = package_dirs(meta)
    owners = set()
    for path in paths:
        candidates = [d for d in by_dir if d and path.startswith(d)]
        if candidates:
            owners.add(by_dir[max(candidates, key=len)])
            continue
        if is_ignored(path):
            continue
        # A file that belongs to no package: the tests cannot be narrowed.
        return False, []
    if not owners:
        return False, []
    return True, sorted(owners)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--paths", required=True)
    parser.add_argument("--metadata", required=True)
    args = parser.parse_args()
    with open(args.metadata, encoding="utf-8") as handle:
        meta = json.load(handle)
    narrow, packages = select(meta, read_paths(args.paths))
    print(f"packages={' '.join(packages)}")
    print(f"narrow={'true' if narrow else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
