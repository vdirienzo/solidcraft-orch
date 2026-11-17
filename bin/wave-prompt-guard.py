#!/usr/bin/env python3
"""Guard: the wave cron prompt on disk must equal the canonical file.

Why this exists (2026-11-05):
The Telegram DM session edited cron job 347ba559cc10's prompt with `hermes cron edit`,
using a STALE copy of the prompt it had in its own context. The write succeeded and silently
destroyed the REGLA DE TURNO / TOPE DE INVESTIGACION / STEP 1b blocks that stop a wave from
spending 43 minutes reading and dispatching nothing. The next wave would have run with the
broken protocol and nobody would have noticed until the work was missing.

A copy in an agent's context is not a source of truth. The canonical file is:
    $ORCH_DIR/prompts/wave-prompt.md

This script runs from a no-agent cron every few minutes. It reads, it compares, and it
RESTORES by re-installing the canonical prompt. It never writes anything else, it never
touches the code, and it prints one line so the cron log says what happened.

Exit codes: 0 = in sync (or restored), 1 = could not restore (needs a human).
"""

from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys

JOB_ID = "347ba559cc10"
ORCH_DIR = os.environ.get("ORCH_DIR", "/home/user/.local/share/solidcraft-orch")
CANONICAL = os.path.join(ORCH_DIR, "prompts", "wave-prompt.md")
JOBS_JSON = os.path.join(os.environ.get("HERMES_HOME", "/home/user/.hermes"), "cron", "jobs.json")
HERMES = os.environ.get("HERMES_BIN", "/home/user/.local/bin/hermes")

# Markers that must be present in the job's prompt. A prompt missing any of them is broken
# even if its bytes differ for some other reason.
REQUIRED_MARKERS = (
    "REGLA DE TURNO",
    "TOPE DE INVESTIGACION",
    "STEP 1b",
    "agent-issue.sh",
    "COMPILE ONLY THROUGH THE GATE",
)


def sha(text: str) -> str:
    return hashlib.sha256(text.strip().encode()).hexdigest()[:12]


def read_job_prompt() -> str | None:
    try:
        with open(JOBS_JSON, encoding="utf-8-sig") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"wave-prompt-guard: cannot read {JOBS_JSON}: {exc}")
        return None
    jobs = data.get("jobs", data) if isinstance(data, dict) else data
    for job in jobs:
        if job.get("id") == JOB_ID:
            prompt = job.get("prompt")
            return prompt if isinstance(prompt, str) else None
    print(f"wave-prompt-guard: job {JOB_ID} not found in {JOBS_JSON}")
    return None


def main() -> int:
    if not os.path.isfile(CANONICAL):
        print(f"wave-prompt-guard: canonical file missing: {CANONICAL}")
        return 1
    with open(CANONICAL, encoding="utf-8") as fh:
        canonical = fh.read()
    current = read_job_prompt()
    if current is None:
        return 1

    missing = [m for m in REQUIRED_MARKERS if m not in current]
    if sha(current) == sha(canonical) and not missing:
        print("wave-prompt-guard: in sync")
        return 0

    print(
        f"wave-prompt-guard: DIVERGED (job sha {sha(current)} != canonical sha {sha(canonical)}"
        + (f", missing markers: {', '.join(missing)}" if missing else "")
        + ") -> restoring"
    )
    try:
        proc = subprocess.run(
            [HERMES, "cron", "edit", JOB_ID, "--prompt", canonical],
            capture_output=True, text=True, timeout=120,
        )
    except (OSError, subprocess.SubprocessError) as exc:
        print(f"wave-prompt-guard: restore failed to start: {exc}")
        return 1
    if proc.returncode != 0:
        print(f"wave-prompt-guard: restore FAILED rc={proc.returncode}: {(proc.stderr or '').strip()[:400]}")
        return 1

    after = read_job_prompt()
    if after is None or sha(after) != sha(canonical):
        print("wave-prompt-guard: restore did not take effect (verify manually)")
        return 1
    print("wave-prompt-guard: restored and verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
