#!/usr/bin/env python3
"""Regression check for the loop's prompts and sandboxes.

Three properties, all mechanical:

1. **Every command a prompt mentions must be runnable by SOME worker.** A
   command nobody can run is a dead instruction: the model burns its steps
   discovering the sandbox, and the turn dies with it.
2. **Every destructive command must be blocked in EVERY worker.** `gh pr
   merge`, `gh issue close`, `gh pr close`, `git push origin` and friends are
   the sandbox's whole point: they are mentioned in the prompts *as things not
   to do*, and a worker that could run them would be a hole.
3. **Every READING command a prompt recommends must be runnable by the agent
   OF THAT PROMPT.** The commands of the other agents (the `git fetch` that
   the worker does, the `cargo test` that the worker does) are mentioned as
   delegations: being blocked is correct. But the reads that the model is
   told to do ITSELF have to work: a denial is a step, and the model falls
   back to `cat`, which reads the whole file. On the 26-10 that was 3,41 M
   of tokens of re-reads of the `ledger.md` (375 kB) and no other reason.

The commands that a prompt marks as DENIED (a fenced block whose first line
says DENIED) must STAY blocked: they are the examples of what NOT to ask
for, and a sandbox that let them through would be a hole.

The matcher implements the permission rules of OpenCode V2: the rules are
evaluated in order and the LAST matching rule wins, `*` is zero or more
characters (it crosses `/` and the spaces), `?` is exactly one character,
and a compound command is denied if ANY of its parts is.
"""
import glob
import os
import re
import sys

AGENT_DIR = os.environ.get("CHECK_AGENT_DIR", "/home/user/.config/opencode/agents")
PROMPT_DIR = os.environ.get("CHECK_PROMPT_DIR", "/home/user/.local/share/solidcraft-loop/prompts")
LOOP_DIR = os.environ.get("CHECK_LOOP_DIR", "/home/user/.local/share/solidcraft-loop")

PROMPT_AGENT = {
    "iteration.md": "sc-orchestrator",
    "triage.md": "sc-triage",
    "claim.md": "sc-claim",
    "implement.md": "sc-implement",
    "gate.md": "sc-gate",
    "evidence.md": "sc-evidence",
    "review.md": "sc-review",
    "publish.md": "sc-publish",
}

# Nothing may run these, in any worker.
FORBIDDEN = (
    "gh pr merge", "gh pr close", "gh issue close", "gh repo delete",
    "git push origin", "git push --force origin",
    "gh issue edit", "gh release", "gh api -X DELETE",
    "gh api -X PATCH", "gh api --method PATCH", "gh api -X PUT",
    "gh api graphql",
)

# Mentioned in the prompts as things NOT to do: they must be blocked
# everywhere, and their being blocked is not a problem.
PROHIBITED_MENTIONS = ("git push", "gh pr *", "gh issue *")

# The commands that READ: the ones the model is told to do itself. A read
# that is blocked is a step lost and a `cat` of the whole file afterwards.
# The commands of the other agents (`git`, `cargo`, `gh`, `bash`) are
# delegations: the model does not run them, the worker does.
READ_VERBS = ("cat", "tail", "head", "wc", "jq", "grep", "ls", "cut", "awk",
              "df", "date", "echo", "sed", "printf", "sort", "uniq", "tr")

# The fences of a prompt. The pairing is done LINE BY LINE and not with a
# regex over the whole text: a regex that only knows the languages "bash",
# "sh" and none SKIPS the fence of a block of json, and then every fence
# after it is paired with the one that follows it. The prose that comes
# after a block of json ends up inside a block, and the checker reads it
# as if it were a command (the sentence "cut is a fact: ..." is a
# sentence, not a `cut`), and the content of a block of shell is never
# read at all: the dead instructions of the prompts went unnoticed.
FENCE_LINE = re.compile(r"^(\s*)(`{3,})[ \t]*([A-Za-z0-9_+.-]*)[ \t]*$")
# The blocks that hold shell commands. A block with no language is a block
# of shell in these prompts; a block of json (or of any other language) is
# not a command.
SHELL_LANGUAGES = ("", "bash", "sh", "shell", "zsh", "console", "shellsession")
INLINE = re.compile(r"`((?:gh|git|cargo|nc|curl|bash|cat|ls|tail|head|jq|date|echo|"
                    r"df|mkdir|solidcraft-cli|printf|grep|wc|cut|awk|test)\s[^`\n]*)`")
SHELL_LINE = re.compile(r"^\s*(?:\$\s*)?((?:gh|git|cargo|nc|curl|bash|cat|ls|tail|head|jq|"
                         r"date|echo|df|mkdir|solidcraft-cli|printf|grep|wc|cut|awk|test)\s.+)$")

# The base policy of opencode: everything is allowed except the secrets.
BASE = [
    ("*", "*", "allow"),
    ("read", "*.env", "ask"),
    ("read", "*.env.*", "ask"),
    ("read", "*.env.example", "allow"),
]


# --- the matcher of the permissions -----------------------------------------
def parse_rules(path):
    """The permission rules of an agent file, in the order they are written."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    if "---" not in text:
        return []
    front = text.split("---")[1]
    rules = []
    for m in re.finditer(
        r"-\s*action:\s*(\S+)\s*\n\s*resource:\s*(.+?)\s*\n\s*effect:\s*(\S+)", front
    ):
        action, resource, effect = m.group(1), m.group(2).strip(), m.group(3)
        resource = resource.strip('"').strip("'")
        rules.append((action, resource, effect))
    return rules


def wildcard_to_re(pattern):
    out = ""
    for ch in pattern:
        if ch == "*":
            out += ".*"
        elif ch == "?":
            out += "."
        else:
            out += re.escape(ch)
    return re.compile("^" + out + "$")


def matches(pattern, value):
    if pattern == value:
        return True
    if wildcard_to_re(pattern).match(value):
        return True
    # a shell pattern ending in " *" also matches the command with no args
    if pattern.endswith(" *") and value == pattern[:-2]:
        return True
    return False


def resolve(rules, action, value):
    """The effect of the LAST matching rule, or (None, None)."""
    effect, rule = None, None
    for a, r, e in rules:
        if a != action:
            continue
        if matches(r, value):
            effect, rule = e, (a, r)
    return effect, rule


def split_compound(cmd):
    """The parts of a compound command, the way the scanner checks them."""
    parts = []
    buf, depth, quote = "", 0, None
    for ch in cmd:
        if quote:
            buf += ch
            if ch == quote:
                quote = None
            continue
        if ch in "'\"":
            quote = ch
            buf += ch
            continue
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if depth == 0 and ch in ";|":
            parts.append(buf.strip())
            buf = ""
            continue
        buf += ch
    if buf.strip():
        parts.append(buf.strip())
    return [p for p in parts if p]


def check(rules, cmd):
    """Evaluate a (possibly compound) command.

    Returns (allowed, list_of_blockers).
    """
    blockers = []
    for part in split_compound(cmd):
        # the redirections and the env assignments are not part of the command
        part = re.sub(r"^(\d*>>?\s*|\d*<&\s*|\S+=\S+\s+)+", "", part).strip()
        part = re.sub(r"\s*2>&1$", "", part).strip()
        effect, rule = resolve(rules, "shell", part)
        if effect == "deny":
            blockers.append((part, rule, effect))
        elif effect is None:
            blockers.append((part, None, "unmatched"))
    return (not blockers), blockers


def load(name):
    """The base policy first, then the agent's own rules.

    The agent's rules are appended last, so they win.
    """
    return BASE + parse_rules(os.path.join(AGENT_DIR, name + ".md"))


# --- the code blocks of a prompt ------------------------------------------------
def fenced_blocks(text):
    """The fenced blocks of a prompt, as (language, body) pairs.

    The pairing is LINE BY LINE: a fence line opens a block and the next
    fence line with no language and at least as many backticks closes it.

    A block that holds another fence is a WRAPPER (the prompts wrap a
    block of json in four backticks): the inner block is the real one and
    the text of the wrapper around it is dropped. Dropping it is the safe
    side: a command that the checker does not see is a command that does
    not raise a false red.

    The old pairing was a regex over the whole text that only knew the
    languages "bash", "sh" and none: the fence of a block of json was
    skipped and every fence after it was paired with the NEXT one. The
    prose that came after a block of json was read as if it were a
    command (the sentence "cut is a fact: ..." is a sentence, not a
    `cut`) and the content of a block of shell was never read at all: the
    dead instructions of the prompts went unnoticed.
    """
    out = []
    _fenced(text.splitlines(), out)
    return out


def _fenced(lines, out):
    """The blocks of `lines`, appended to `out` as (language, body)."""
    i = 0
    n = len(lines)
    while i < n:
        m = FENCE_LINE.match(lines[i])
        if not m:
            i += 1
            continue
        marker = len(m.group(2))
        lang = m.group(3)
        # the closing fence: no language and at least as many backticks
        j = i + 1
        close = None
        while j < n:
            c = FENCE_LINE.match(lines[j])
            if c and not c.group(3) and len(c.group(2)) >= marker:
                close = j
                break
            j += 1
        if close is None:
            close = n
        body = lines[i + 1:close]
        if any(FENCE_LINE.match(line) for line in body):
            _fenced(body, out)          # a wrapper: the inner block is real
        else:
            out.append((lang, body))
        i = close + 1


def is_shell(lang):
    """A block of shell: the one whose commands are commands."""
    return lang.lower() in SHELL_LANGUAGES


# --- the commands of a prompt --------------------------------------------------
def commands(text):
    """The commands a prompt mentions, in the code blocks and inline."""
    out = []
    for lang, body in fenced_blocks(text):
        if not is_shell(lang):
            continue
        for raw in body:
            m = SHELL_LINE.match(raw)
            if m:
                out.append(m.group(1).strip())
    for m in INLINE.finditer(text):
        out.append(m.group(1).strip())
    return out


def denied_commands(text):
    """The commands a prompt marks as DENIED.

    A fenced block whose first line says DENIED is the list of what NOT to
    ask for. Those commands have to STAY blocked.
    """
    out = []
    for lang, body in fenced_blocks(text):
        if not is_shell(lang):
            continue
        lines = body
        if not lines or "DENIED" not in lines[0]:
            continue
        for raw in lines[1:]:
            m = SHELL_LINE.match(raw)
            if m:
                out.append(m.group(1).strip())
    return out


def normalize(cmd):
    """The placeholders of a prompt become a real path.

    `<path>` is a path of the loop dir: a command with a placeholder is a
    SYNTAX example, and it has to be checked against a real path to say
    anything about the sandbox.
    """
    cmd = re.sub(r"<path>", f"{LOOP_DIR}/ledger.md", cmd)
    cmd = re.sub(r"<file>", f"{LOOP_DIR}/ledger.md", cmd)
    cmd = re.sub(r"<S>", "0", cmd)
    cmd = re.sub(r"<N>", "1", cmd)
    cmd = re.sub(r"<[^>]*>", "X", cmd)
    return cmd.replace("...", f"{LOOP_DIR}/bin")


def is_read(cmd):
    """A command that reads: the first word is one of the read utilities."""
    first = cmd.split()[0] if cmd.split() else ""
    return first in READ_VERBS


def main():
    agents = sorted(os.path.basename(p)[:-3] for p in glob.glob(os.path.join(AGENT_DIR, "sc-*.md")))
    if not agents:
        print(f"no hay agentes en {AGENT_DIR}")
        return 1
    rules = {a: load(a) for a in agents}
    dead = []
    holes = []
    unreadable = []
    leaked = []

    for prompt, agent in sorted(PROMPT_AGENT.items()):
        path = os.path.join(PROMPT_DIR, prompt)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8") as fh:
            text = fh.read()
        denied = {normalize(c) for c in denied_commands(text)}
        seen = set()
        for cmd in commands(text):
            cmd = normalize(cmd)
            if cmd in seen:
                continue
            seen.add(cmd)

            # 2. a destructive command must be blocked everywhere
            if any(cmd.startswith(f) for f in FORBIDDEN):
                for a in agents:
                    ok, blockers = check(rules[a], cmd)
                    if ok:
                        holes.append((prompt, a, cmd))
                continue

            # mentioned as prohibited: being blocked is the correct outcome
            if cmd in PROHIBITED_MENTIONS:
                for a in agents:
                    ok, _ = check(rules[a], cmd)
                    if ok:
                        holes.append((prompt, a, cmd))
                continue

            # 1. somebody must be able to run it. The commands that the
            # prompt marks as DENIED are the opposite: the prompt says NOT
            # to ask for them, so nobody running them is the correct outcome.
            if cmd not in denied and not any(check(rules[a], cmd)[0] for a in agents):
                dead.append((prompt, cmd))

            # 3. a READ that the prompt recommends has to be runnable by the
            # agent of THIS prompt: the model does the reads itself. The
            # commands that the prompt marks as DENIED are the opposite: the
            # prompt says NOT to ask for them, so being blocked is correct.
            if cmd in denied:
                continue
            if is_read(cmd) and not check(rules[agent], cmd)[0]:
                unreadable.append((prompt, agent, cmd))

        # the commands the prompt marks as DENIED have to stay blocked for
        # the agent that reads the prompt
        for cmd in denied:
            ok, _ = check(rules[agent], cmd)
            if ok:
                leaked.append((prompt, agent, cmd))

    print("=" * 70)
    print("1. comandos que NINGÚN worker puede correr (instrucciones muertas):")
    if dead:
        for prompt, cmd in dead:
            print(f"   [{prompt}] {cmd!r}")
    else:
        print("   (ninguno)")

    print()
    print("2. comandos destructivos que ALGÚN worker podría correr (agujeros):")
    if holes:
        for prompt, agent, cmd in holes:
            print(f"   [{prompt}] [{agent}] PODRÍA correr {cmd!r}")
    else:
        print("   (ninguno)")

    print()
    print("3. lecturas que el prompt recomienda y su agente NO puede correr:")
    if unreadable:
        for prompt, agent, cmd in unreadable:
            print(f"   [{prompt}] [{agent}] NO puede correr {cmd!r}")
    else:
        print("   (ninguna)")

    print()
    print("4. comandos marcados como DENIED que el agente del prompt PODRÍA correr:")
    if leaked:
        for prompt, agent, cmd in leaked:
            print(f"   [{prompt}] [{agent}] PODRÍA correr {cmd!r}")
    else:
        print("   (ninguno)")

    return 1 if (dead or holes or unreadable or leaked) else 0


if __name__ == "__main__":
    sys.exit(main())
