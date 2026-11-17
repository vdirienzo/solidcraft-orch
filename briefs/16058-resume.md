# TASK 16058 — RESUME brief (the work is done; verify, commit, publish)

Issue: https://github.com/tangency-labs/solidcraft/issues/16058

## The state of the work

Two previous runs of this task built the change; both were killed by the model
provider's connection reset before they could publish. ALL of their work is safe on
local branches of this same repository:

    salvage/issue-16058      the first run's commit
    salvage/issue-16058b     the second run's commit (the later one, it has everything)

**Your FIRST action, before anything else, is:**

    git cherry-pick salvage/issue-16058b

(If it reports a conflict, resolve it in favour of the salvage version and say so in
your report.) Do NOT rewrite the design and do NOT re-plan it.

After that cherry-pick the branch already contains the WHOLE change:

* a new command `view.browser` that opens and closes the Browser tree
  (`crates/engine/src/cmd/view_navigation.rs` and
  `crates/engine/src/schema/view_navigation.rs`);
* the UI that shows the tree (`crates/ui-egui/src/browser.rs`, `control.rs`, `lib.rs`,
  `workspace.rs`, `command_help.rs`);
* the View MENU row: `crates/ui-egui/src/navigation_bar_view.rs`, in `fn display_menu`,
  a row with the id `browser_tree`, the label `cmd.view_browser`, the icon `list`, the
  handle `view:browser_tree`, and the checkbox state from `crate::browser::panel_open`;
  and in `fn display_pick`, the arm `browser_tree` that runs `view.browser`;
* the Layout setting that also brings the tree back
  (`crates/ui-egui/src/prefs/interface.rs`, the control published with the handle
  `prefs:browser_tree`);
* the new UI strings in `assets/locales/pending/browser-tree-panel.json` (the keys
  `cmd.view_browser`, `help.view.browser`, `prefs.layout_page.browser_tree` and
  `prefs.layout_page.browser_tree_note` are already there);
* the regression test `the_view_menu_brings_the_browser_tree_back` in
  `crates/ui-egui/src/view_home_tests.rs` (the area's EXISTING test file);
* the entry `view.browser` in `tests/kernel-cases/EXEMPT`.

## What is left for you to do — exactly this

1. Run the gate and make sure it is GREEN:

       cargo fmt --all
       cargo test -p solidcraft-ui-egui

   The slot's target directory is already warm, so this should be reasonably fast.
   If the test `the_view_menu_brings_the_browser_tree_back` fails, fix the
   implementation (not the test) until it passes.

   Save the output to `/home/user/.local/share/solidcraft-orch/logs/16058-GREEN.log`.

2. Check the sorted lists:

       cargo xtask lists

   The new command `view.browser` must be in the right alphabetical place in every
   list it belongs to, including `tests/kernel-cases/EXEMPT`.

3. Commit everything and make sure the tree is CLEAN. The previous run FAILED TO
   PUBLISH because `cargo fmt` left the reformatting uncommitted and the harness
   refuses to rebase a tree with unstaged changes:

       git add -A
       git status --porcelain     # MUST be empty

   The final state of the branch must be ONE commit on top of
   `refs/remotes/agent/upstream-main` with this exact message:

```
UI: the browser tree can be brought back from the View menu

Task: https://github.com/tangency-labs/solidcraft/issues/16058
```

   (If the cherry-pick produced two commits, squash them:
   `git reset --soft refs/remotes/agent/upstream-main && git commit`.)

## Hard rules

- English code, English test names, English comments.
- No `unwrap()`/`expect()`/`panic!` in non-test code (the test file may use them).
- Do not touch `crates/kernel`.
- The regression test stays in `crates/ui-egui/src/view_home_tests.rs`, the area's
  existing test file. Do NOT create a new test file.
- This does NOT change a default of the application: it adds a menu row and a
  preference control, it changes no stored value and no default behaviour of a
  feature that already existed. The pull request body must contain exactly
  `Changes a default: no`.
- Do NOT push, do NOT open a pull request, do NOT merge, do NOT rebase. The harness
  publishes the branch and opens the pull request.
- Do not run `cargo xtask ci` (90 minutes). The narrow gate above is what you run.
