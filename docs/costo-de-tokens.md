# El costo de los tokens: la medicion completa

Todo lo de abajo son `usage` reales devueltos por la API de MiniMax
(`https://api.minimax.io/anthropic/v1/messages`, modelo `MiniMax-M3.1-Flash`), no estimaciones.
El informe largo esta en `/home/user/.local/share/solidcraft-orch/reports/auditoria-tokens-2026-11-03.md`.

Measured against MiniMax-M3.1-Flash (input $0,15/M, OUTPUT $0,60/M, cache read $0,015/M) on a real
session of 16 calls: input $0,0117 (20%), output $0,0157 (27%), cache $0,0313 (53%). The provider
caches the WHOLE request automatically (277.760 cache read on a 993 KB request), so the size of the
request is not the cost: the cost is the cache MISSES and the OUTPUT.

A subagent that runs to 250 iterations costs about $1,17 and delivers nothing (625k output tokens,
32,5M cache read, three context compressions of ~$0,04 and 104 seconds each, and each compression
rebuilds the system prompt, which breaks the cache prefix).

The cache expires between 7 and 17 minutes of silence (measured: alive at 7 min, gone at 17 min);
a miss bills the whole prefix at input price, 10x the cache price. A cargo compilation takes 10-25
minutes, so each one is a guaranteed miss.

So, on every dispatch:
- pass `max_iterations: 120` (a stuck agent costs $1,17 to learn nothing);
- ask for the reads in ONE `execute_code` call (ten files in one tool call, not ten `read_file`):
  the history grows ~3k output tokens plus the tool_result per call, and 250 calls is 750k tokens
  and three compressions;
- ask for the heavy work (the cargo compilation) at the END, not in the middle;
- ask for a SHORT summary: it comes back into the orchestrator's context.

Do NOT touch `compression.threshold` (the cache is healthy: 96% of the input is served from it) and
do NOT lower `thinking.budget_tokens` (real usage is 1,6k-3k of the 8k available, so the ceiling is
not what you pay). Details and the full measurement: `docs/costo-de-tokens.md`.

## The recurring jobs cost nothing when they are scripts, and they cost a fortune when they are agents
A scheduled job that opens a Hermes session spends the whole context on every call: the report that
ran as an agent job cost about 1.5M prompt tokens per run. The same job as `--script X --no-agent`
spends ZERO model tokens, because the script does the collection AND the wording and its stdout is
delivered as-is.

Three details that decide whether the no-agent recipe actually works:
- the script must live in `~/.hermes/scripts/` and the path passed to `--script` is RELATIVE to
  that directory; the file is resolved when the job is CREATED, so a script that is not there yet
  fails the create with "Script file not found" (the fix is to copy the script first, not to
  create the job and hope);
- a cron calls the script with NO arguments, so its default branch has to be the useful one — a
  script that only prints its usage leaves the job doing nothing, silently, every tick;
- `--deliver local` keeps the output on disk instead of pushing it to a chat, which is what a
  maintenance job wants.

The same shape applies to the maintenance jobs of the box itself (renicing the compilations,
draining the gate queue): each one is a script, each one runs from a cron every few minutes, and
each one must do its work in its DEFAULT branch.

## The cost of a subagent that dies is paid TWICE if you re-dispatch it
A child that reaches the iteration cap has usually already committed and pushed its work: the
cap is reached at the END of a run, and the summary is what gets truncated, not the work. So a
truncated summary is a reason to go READ the worktree and the remote head, never a reason to
dispatch a replacement — a replacement re-derives a settled design and burns its own budget
before it writes anything.

