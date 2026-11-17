You are working in the SolidCraft repository (a Rust workspace). Read `AGENTS.md` at the root of the repository first and follow it: the code and the tests are written in English, a test lives in the same file as the code it tests, and one pull request carries one topic and one issue.

## The task

{{TITLE}}

{{BODY}}

## The rules of this repository

- the test goes in the same file as the code it tests, in the `mod tests` block that is already there;
- the code and the test are written in English;
- the quality gate is `cargo xtask ci`, but for a change this small run the narrow gate: `cargo fmt` on the touched crate and `cargo test -p <crate>`;
- one topic, one issue, one pull request.

## The gate you must run

```
cargo fmt --all
cargo test -p <crate>
```

Do NOT run the full `cargo xtask ci`: it takes about 90 minutes on a saturated machine. The pull request's own CI runs the full gate on GitHub's runners.

## When you are done

1. `git status` and make sure only the files the task needs changed.
2. Commit with a message that references the task by its full URL, for example:

```
<short description>

Task: {{ISSUE_URL}}
```

3. Do NOT push and do NOT open the pull request: the harness does that, after it checks that the gate passed and that you touched nothing else.

## What you must not do

- Do not merge, close, rebase or force-push anything.
- Do not change the CI workflows, the xtask, `AGENTS.md` or any other file.
- Do not leave backup files (`.bak`, `.orig`) or generated files behind.
- Do not run the full `cargo xtask ci`.
- Do not work on the branch `{{BRANCH}}` only by guess: check `git branch --show-current` first, and commit there.
