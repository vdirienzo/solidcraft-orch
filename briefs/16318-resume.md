# TASK 16318 — RESUME brief (the first agent died on a transport reset; its work survives)

Issue: https://github.com/tangency-labs/solidcraft/issues/16318

## The report

Title: "AI Agent Does Not Resume After Usage Limit Resets".

When the provider's usage limit is hit, the agent stops with
"Internal error: You've hit your 5-hour limit · resets 6:30pm" and never continues when
the limit resets. Expected: the task can be resumed from where it stopped.

The upstream maintainer (raykholo) triaged it: "the Assistant panel does not keep a
task to continue after the provider's usage limit resets".

## STATE OF THE WORK: THE IMPLEMENTATION AND THE TEST ARE ALREADY COMMITTED

The previous agent wrote the implementation AND its test. It is COMMITTED in the
worktree `/home/user/solidcraft-wt/issue-16318`:

    commit e66b540daa1d3d8758918580a91053928efdb14b
    (message: 'Agent: a task interrupted by the provider can be continued')
    crates/ui-egui/src/agent_chat/mod.rs   | 28 +
    crates/ui-egui/src/agent_chat/panel.rs  | 16 +
    crates/ui-egui/src/agent_chat/tests.rs  | 44 +

WHAT IT DOES (read the diff before changing anything):

- `AgentChat` gains a field `unfinished: Option<(String, bool, Option<usize>,
  Vec<attach::Attachment>)>`: the task of a turn the agent could not finish.
- When a turn ends with `reason == "error"`, `self.unfinished = self.last.clone()`.
- A new `pub fn continue_task(app: &mut SolveApp)` sends that task again with a
  `CONTINUE_NOTE` ("[The previous attempt was cut short before it finished. Continue
  the task from where it stopped.]"), without repeating it in the conversation.
- `leave_document` and `new_chat` clear it.

### What you must do

1. CHECK THE WORK COMPILES and the test passes. Run the test the agent wrote (its
   name is in `crates/ui-egui/src/agent_chat/tests.rs`; look at the commit):

       cargo nextest run -p solidcraft-ui-egui -E 'test(<the agent chat test>)'

   If it does not compile, fix it. If it does not pass, fix it.

2. THE TEST MUST BE MEANINGFUL. The agent's test must FAIL without the change: check
   that it really asserts the behaviour (the task is kept when the turn ends with an
   error, and it can be continued). If the test would pass without the change, it is
   not a regression test: fix the test.

3. CHECK THE PANEL PART. `crates/ui-egui/src/agent_chat/panel.rs` was changed too
   (+16 lines). Make sure the user can actually reach `continue_task` from the panel
   (a button or a key) and that the button appears only when there is an unfinished
   task and the agent is ready. If the agent left the panel half-wired, finish it.

4. RUN THE GATE: `cargo fmt --all` and the nextest of `solidcraft-ui-egui` limited to
   the agent chat tests (`cargo nextest run -p solidcraft-ui-egui -E 'test(agent_chat)'`).
   Save the output to `/home/user/.local/share/solidcraft-orch/logs/16318-GREEN.log`.

5. SAVE THE RED EVIDENCE: if the test fails when the implementation is reverted, save
   that output to `/home/user/.local/share/solidcraft-orch/logs/16318-RED.log`
   (`git stash` the implementation, run the test, `git stash pop`).

6. THE COMMIT MESSAGE must be:

      Agent: a task interrupted by the provider's usage limit can be continued

      Task: https://github.com/tangency-labs/solidcraft/issues/16318

   The pull request body must contain exactly `Changes a default: no` and
   `Fixes #16318`.

7. IF the work turns out to be wrong (the behaviour cannot be what the report asks
   for, or the panel cannot offer it), report that and open NO pull request.

### Housekeeping

- Do NOT push, do NOT open a pull request, do NOT merge, do NOT rebase.
- English code, English test names, English comments.
- No `unwrap()`/`expect()`/`panic!` in non-test code. Do not touch `crates/kernel`.
- The test goes in the area's EXISTING test file, never in a new per-bug file.
- Build with `CARGO_BUILD_JOBS=2` and `CARGO_INCREMENTAL=0`; the machine is shared.
- Do NOT run the full `cargo xtask ci` (90 minutes) nor the whole crate's suite: run
  only the agent chat tests.
- Work in the order: make it compile, make the test pass, gate, commit. If you are
  near the end of your turns, commit what you have.
