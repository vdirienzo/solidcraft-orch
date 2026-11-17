#!/usr/bin/env bash
# docs-html.sh - regenerate the human-readable HTML page of the SolidCraft loop.
#
# The page is a self-contained sibling of RUNBOOK.md: inline CSS, no external
# assets, no JavaScript, readable offline and in both colour schemes.
#
# The script reads the live state (state.json, disk.status, the ledger) and the
# GitHub pull requests of the loop author, then writes docs/index.html (the
# name a static site needs, so the directory can be published as it is).
#
# It never fails: every data source is optional.  When a value is not
# available the page says "sin datos" instead of breaking.
#
# Usage:  bash ~/.local/share/solidcraft-loop/bin/docs-html.sh [--dry-run] [--deploy]

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOOP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
DOCS_DIR="$LOOP_DIR/docs"
OUT_FILE="$DOCS_DIR/index.html"
# The Vercel project the page is published to.
VERCEL_PROJECT="${VERCEL_PROJECT:-solidcraft-loop}"

REPO="tangency-labs/solidcraft"
AUTHOR="vdirienzo"

STATE_FILE="$LOOP_DIR/state.json"
LEDGER_FILE="$LOOP_DIR/ledger.md"
LEDGER_ARCHIVE_DIR="$LOOP_DIR/ledger"
DISK_STATUS="$LOOP_DIR/disk.status"

# gh lives in ~/.local/bin and the vercel CLI in ~/.local/node/bin: neither is
# always on the PATH of the caller.
export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$PATH"

DRY_RUN=0
DEPLOY=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --deploy)  DEPLOY=1 ;;
  esac
done

TMP_FILE=""
TMP_OPEN=""
TMP_CLOSED=""
cleanup() {
  [ -n "${TMP_FILE:-}" ] && [ -f "${TMP_FILE:-}" ] && rm -f "$TMP_FILE"
  [ -n "${TMP_OPEN:-}" ] && [ -f "${TMP_OPEN:-}" ] && rm -f "$TMP_OPEN"
  [ -n "${TMP_CLOSED:-}" ] && [ -f "${TMP_CLOSED:-}" ] && rm -f "$TMP_CLOSED"
  return 0
}
trap cleanup EXIT

# ------------------------------------------------------------------ utils --

# esc - escape a string so it is safe inside HTML text and attributes.
esc() {
  local s="${1-}"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
  s="${s//\'/&#39;}"
  printf '%s' "$s"
}

# cfg_val KEY FILE - read KEY=VALUE from a shell-like file; empty when absent.
cfg_val() {
  local key="$1" file="$2" val=""
  if [ -f "$file" ]; then
    val=$(grep -m1 -E "^[[:space:]]*${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-)
    val="${val%$'\r'}"
    val="${val//\"/}"
    val="${val//\'/}"
    val="${val# }"
    val="${val% }"
  fi
  printf '%s' "$val"
}

# jq_num FILE FILTER - read a scalar from a JSON file; empty when missing.
jq_num() {
  local file="$1" filter="$2" val=""
  if [ -f "$file" ] && command -v jq >/dev/null 2>&1; then
    val=$(jq -r "${filter} // empty" "$file" 2>/dev/null | head -1)
  fi
  printf '%s' "$val"
}

# date_of ISO - turn an ISO timestamp into dd-mm-yyyy; empty when unusable.
date_of() {
  local ts="${1:-}" out=""
  if [ -n "$ts" ]; then
    out=$(date -u -d "$ts" '+%d-%m-%Y' 2>/dev/null)
  fi
  [ -z "$out" ] && out=$(printf '%s' "$ts" | cut -c1-10)
  printf '%s' "$out"
}

# badge CLASS TEXT - a coloured pill used to mark a state.
badge() {
  printf '<span class="badge %s">%s</span>' "$1" "$(esc "$2")"
}

# --- the ledger -------------------------------------------------------------
# The ledger is split: the old rows live in the gzip chunks of the `ledger`
# directory next to the ledger (ledger-YYYY-MM.md.gz) and the current
# ledger.md holds the rows that are not archived yet. Every file is read,
# the oldest chunk first and the current file last.

# ledger_chunk_key NAME - the order of an archived chunk: the month of the
# name first, the names that do not follow it last.
ledger_chunk_key() {
  local name="${1-}"
  if [[ "$name" =~ ^ledger-([0-9]{4})-([0-9]{2}) ]]; then
    printf '%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
  else
    printf '9999-99'
  fi
}

# ledger_sources - the files of the ledger, in chronological order.
ledger_sources() {
  local path name key
  {
    for path in "$LEDGER_ARCHIVE_DIR"/*.gz; do
      [ -f "$path" ] || continue
      name="${path##*/}"
      key="$(ledger_chunk_key "$name")"
      printf '%s\t%s\n' "$key" "$path"
    done
  } | LC_ALL=C sort | cut -f2-
  printf '%s\n' "$LEDGER_FILE"
}

# ledger_rows FILE PATTERN - the rows of one ledger file that match an
# extended regular expression. A chunk that is broken is reported on stderr
# and counted as zero rows: the page must be generated anyway.
ledger_rows() {
  local path="${1-}" pattern="${2-}" rows=""
  if [ ! -f "$path" ]; then
    printf '0'
    return 0
  fi
  case "$path" in
    *.gz)
      if ! gzip -t "$path" 2>/dev/null; then
        printf 'docs-html: the ledger chunk could not be read: %s\n' "$path" >&2
        printf '0'
        return 0
      fi
      rows="$(gzip -cd "$path" 2>/dev/null | grep -cE "$pattern" || true)"
      ;;
    *)
      rows="$(grep -cE "$pattern" "$path" 2>/dev/null || true)"
      ;;
  esac
  case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
  printf '%s' "$rows"
}

# ledger_count PATTERN - the rows of the whole ledger that match the
# pattern: the archived chunks and the current file.
ledger_count() {
  local pattern="${1-}" path rows total=0
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    rows="$(ledger_rows "$path" "$pattern")"
    total=$(( total + rows ))
  done < <(ledger_sources)
  printf '%s' "$total"
}

# ledger_has_files - true when the ledger has at least one file to read.
ledger_has_files() {
  local path
  while IFS= read -r path; do
    if [ -n "$path" ] && [ -f "$path" ]; then
      return 0
    fi
  done < <(ledger_sources)
  return 1
}

# ------------------------------------------------------------------- data --

TODAY_UTC="$(date -u '+%Y-%m-%d')"
GEN_STAMP="$(date -u '+%d-%m-%Y %H:%M:%S UTC')"

# Loop counters, straight from the state file.
iterations=$(jq_num "$STATE_FILE" '.counters.iterations')
failures=$(jq_num "$STATE_FILE" '.counters.failures')
if [ -z "$iterations" ] && ledger_has_files; then
  iterations=$(ledger_count '^\| 20')
fi
if [ -z "$failures" ] && ledger_has_files; then
  failures=$(ledger_count '\| failed \|')
fi
[ -z "$iterations" ] && iterations="sin datos"
[ -z "$failures" ] && failures="sin datos"

# Pull requests published by the loop today.
published_today=""
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  published_today=$(jq -r --arg d "$TODAY_UTC" '
    if (.published // null) == null then empty else ((.published[$d] // []) | length) end
  ' "$STATE_FILE" 2>/dev/null | head -1)
fi
[ -z "$published_today" ] && published_today="sin datos"

# Disk status of the last cleanup pass.
disk_free=""
disk_freed=""
disk_actions=""
disk_skipped=""
disk_last=""
disk_have=0
if [ -f "$DISK_STATUS" ]; then
  disk_have=1
  disk_free=$(cfg_val FREE_GB "$DISK_STATUS")
  disk_freed=$(cfg_val FREED_GB "$DISK_STATUS")
  disk_actions=$(cfg_val ACTIONS "$DISK_STATUS")
  disk_skipped=$(cfg_val SKIPPED "$DISK_STATUS")
  disk_last=$(cfg_val LAST_RUN "$DISK_STATUS")
fi
if [ "$disk_have" = "1" ]; then
  disk_free_text="${disk_free:-sin datos} GB"
  disk_label="${disk_free:-sin datos} GB libres"
  disk_last_text=""
  if [ -n "$disk_last" ]; then
    disk_last_text=$(date -u -d "@$disk_last" '+%d-%m-%Y %H:%M' 2>/dev/null)
    [ -z "$disk_last_text" ] && disk_last_text="$disk_last"
  else
    disk_last_text="sin datos"
  fi
  disk_detail="última pasada: ${disk_last_text} · liberados: ${disk_freed:-sin datos} GB · acciones: ${disk_actions:-sin datos} · saltadas: ${disk_skipped:-sin datos}"
else
  disk_free_text="sin limpieza todavía"
  disk_label="sin limpieza todavía"
  disk_detail="sin limpieza todavía"
fi

# Our pull requests: the open ones plus the recently merged ones.
prs_open_raw=""
prs_closed_raw=""
if command -v gh >/dev/null 2>&1; then
  if command -v timeout >/dev/null 2>&1; then
    prs_open_raw=$(timeout 60 gh pr list --repo "$REPO" --author "$AUTHOR" --state open --limit 40 \
      --json number,title,createdAt,updatedAt,closedAt,mergedAt,isDraft,state,headRefName < /dev/null 2>/dev/null)
    prs_closed_raw=$(timeout 60 gh pr list --repo "$REPO" --author "$AUTHOR" --state closed --limit 40 \
      --json number,title,createdAt,updatedAt,closedAt,mergedAt,isDraft,state,headRefName < /dev/null 2>/dev/null)
  else
    prs_open_raw=$(gh pr list --repo "$REPO" --author "$AUTHOR" --state open --limit 40 \
      --json number,title,createdAt,updatedAt,closedAt,mergedAt,isDraft,state,headRefName < /dev/null 2>/dev/null)
    prs_closed_raw=$(gh pr list --repo "$REPO" --author "$AUTHOR" --state closed --limit 40 \
      --json number,title,createdAt,updatedAt,closedAt,mergedAt,isDraft,state,headRefName < /dev/null 2>/dev/null)
  fi
fi
prs_open_json="$prs_open_raw"
prs_closed_json="$prs_closed_raw"
[ -n "$prs_open_json" ] || prs_open_json="[]"
[ -n "$prs_closed_json" ] || prs_closed_json="[]"

open_count=""
if [ -n "$prs_open_raw" ] && command -v jq >/dev/null 2>&1; then
  open_count=$(printf '%s' "$prs_open_raw" | jq -r 'length' 2>/dev/null | head -1)
fi
[ -z "$open_count" ] && open_count="sin datos"

TMP_OPEN="$(mktemp "${TMPDIR:-/tmp}/docs-open.XXXXXX" 2>/dev/null)"
TMP_CLOSED="$(mktemp "${TMPDIR:-/tmp}/docs-closed.XXXXXX" 2>/dev/null)"
if [ -z "$TMP_OPEN" ] || [ -z "$TMP_CLOSED" ]; then
  printf 'No se pudieron crear los ficheros temporales: no hay pull requests.\n' >&2
  TMP_OPEN=""
  TMP_CLOSED=""
fi
printf '%s\n' "$prs_open_json" > "$TMP_OPEN"
printf '%s\n' "$prs_closed_json" > "$TMP_CLOSED"

# Merge both lists, newest activity first, and keep the 15 most recent.
# The rows are joined with US (unit separator): a tab would be eaten by the
# shell reader, because consecutive tabs collapse into a single delimiter.
pr_rows=""
if [ -n "$TMP_OPEN" ] && [ -n "$TMP_CLOSED" ]; then
  pr_rows=$(jq -s -r '
    (add // [])
    | map(select((.mergedAt != null) or (.state == "OPEN") or (.state == "MERGED")))
    | unique_by(.number)
    | map(. + {sortkey: (if .mergedAt != null then .mergedAt else (.updatedAt // .createdAt // "") end)})
    | sort_by(.sortkey) | reverse
    | .[:15]
    | .[]
    | [ (.number|tostring), (.title // ""), (.isDraft|tostring), (.state // ""),
        (.mergedAt // ""), (.closedAt // ""), (.createdAt // ""), (.updatedAt // "") ]
    | join("\u001f")
  ' "$TMP_OPEN" "$TMP_CLOSED" 2>/dev/null)
fi
[ -z "$pr_rows" ] && pr_rows=""

pr_rows_count=0
if [ -n "$pr_rows" ]; then
  pr_rows_count=$(printf '%s\n' "$pr_rows" | grep -c '[^[:space:]]' 2>/dev/null)
fi

# The issue a pull request fixes: from the title first, from the body if not.
issue_from_title() {
  local t="$1" n=""
  n=$(printf '%s' "$t" | grep -oE '\(#[0-9]+\)' 2>/dev/null | head -1 | grep -oE '[0-9]+')
  if [ -z "$n" ]; then
    n=$(printf '%s' "$t" | grep -oE '#[0-9]+' 2>/dev/null | head -1 | tr -d '#')
  fi
  printf '%s' "$n"
}

issue_from_body() {
  local num="$1" body="" n=""
  command -v gh >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    body=$(timeout 30 gh pr view "$num" --repo "$REPO" --json body -q .body < /dev/null 2>/dev/null)
  else
    body=$(gh pr view "$num" --repo "$REPO" --json body -q .body < /dev/null 2>/dev/null)
  fi
  if [ -n "$body" ]; then
    n=$(printf '%s' "$body" | grep -oiE '(fixes|closes|resolves)[[:space:]]+#([0-9]+)' 2>/dev/null | head -1 | grep -oE '[0-9]+')
  fi
  printf '%s' "$n"
}

# feature_of TITLE - split a title into an area tag and a one-line description.
# The text is never rewritten: it is the title of the pull request, minus the
# trailing issue reference.
feature_of() {
  local t="${1-}"
  local area=""
  local rest="$t"
  local prefix="${t%%:*}"
  if [ "$prefix" != "$t" ] && [ "${#prefix}" -le 24 ]; then
    local words
    words=$(printf '%s' "$prefix" | wc -w | tr -d ' ')
    if [ -n "$words" ] && [ "$words" -le 4 ]; then
      area="$prefix"
      rest="${t#*: }"
      rest="${rest#:}"
    fi
  fi
  rest=$(printf '%s' "$rest" | sed -E 's/[[:space:]]*\(#?[0-9]+\)[[:space:]]*$//')
  rest="${rest%"${rest##*[![:space:]]}"}"
  printf '%s|%s' "$area" "$rest"
}

# ------------------------------------------------------------- the output --

mkdir -p "$DOCS_DIR" 2>/dev/null
TMP_FILE="$(mktemp "${TMPDIR:-/tmp}/loop.html.XXXXXX" 2>/dev/null)"
if [ -z "$TMP_FILE" ] || [ ! -f "$TMP_FILE" ]; then
  printf 'No se pudo crear el fichero temporal: no se escribe nada.\n' >&2
  exit 1
fi

# --- head + inline stylesheet ------------------------------------------------
cat > "$TMP_FILE" <<'HTML_HEAD'
<!DOCTYPE html>
<html lang="es">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>El loop de SolidCraft</title>
<style>
:root {
  color-scheme: light dark;
  --bg: #f4f6f9;
  --fg: #171b21;
  --muted: #59626e;
  --card: #ffffff;
  --border: #d7dde5;
  --code-bg: #eef1f5;
  --accent: #23508f;
  --ok-fg: #12603a;
  --ok-bg: #e2f3e9;
  --warn-fg: #7d5100;
  --warn-bg: #fbeed4;
  --bad-fg: #97201d;
  --bad-bg: #f9e3e2;
  --info-fg: #1c4f85;
  --info-bg: #e4eefa;
  --mut-fg: #4c545f;
  --mut-bg: #e9ecf1;
  --shadow: 0 1px 2px rgba(16, 24, 40, .06), 0 1px 3px rgba(16, 24, 40, .08);
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #0f1319;
    --fg: #e4e8ee;
    --muted: #98a2b1;
    --card: #171d25;
    --border: #2a323d;
    --code-bg: #1d242d;
    --accent: #8fb2ef;
    --ok-fg: #74d6a1;
    --ok-bg: #14301f;
    --warn-fg: #e9bb63;
    --warn-bg: #342811;
    --bad-fg: #f08d8a;
    --bad-bg: #3a1d1c;
    --info-fg: #86b7ec;
    --info-bg: #17293a;
    --mut-fg: #a6b0bd;
    --mut-bg: #232a34;
    --shadow: none;
  }
}
* { box-sizing: border-box; }
html { -webkit-text-size-adjust: 100%; }
body {
  margin: 0;
  background: var(--bg);
  color: var(--fg);
  font-family: system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  font-size: 16px;
  line-height: 1.55;
}
.wrap { max-width: 1180px; margin: 0 auto; padding: 24px 16px 56px; }
h1, h2, h3, h4 { line-height: 1.25; margin: 0 0 .4em; }
h1 { font-size: 1.85rem; letter-spacing: -.015em; }
h2 { font-size: 1.35rem; }
h3 { font-size: 1.08rem; }
h4 { font-size: .98rem; }
p { margin: 0 0 .8em; }
a { color: var(--accent); }
code, kbd {
  font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, "Liberation Mono", monospace;
  font-size: .88em;
  background: var(--code-bg);
  border: 1px solid var(--border);
  border-radius: 4px;
  padding: .08em .34em;
  word-break: break-word;
}
pre { margin: 0 0 .8em; }
pre code { display: block; padding: 12px 14px; overflow-x: auto; }
section {
  background: var(--card);
  border: 1px solid var(--border);
  border-radius: 12px;
  box-shadow: var(--shadow);
  padding: 22px 22px 24px;
  margin: 0 0 22px;
}
.lead { font-size: 1.08rem; color: var(--fg); max-width: 78ch; }
.note { color: var(--muted); font-size: .92rem; }
.gen { color: var(--muted); font-size: .86rem; margin: 0 0 18px; }
.section-head { border-bottom: 1px solid var(--border); padding-bottom: 10px; margin-bottom: 16px; }
.section-head h2 { margin: 0; }
.metrics {
  list-style: none;
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
  gap: 10px;
  margin: 0 0 18px;
  padding: 0;
}
.metrics li {
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 10px 12px;
  background: var(--bg);
}
.metrics .k { display: block; color: var(--muted); font-size: .78rem; text-transform: uppercase; letter-spacing: .05em; }
.metrics .v { display: block; font-size: 1.4rem; font-weight: 650; margin-top: 2px; }
.metrics .v.bad { color: var(--bad-fg); }
.metrics .v.ok { color: var(--ok-fg); }
.table-wrap { overflow-x: auto; margin: 0 0 14px; border: 1px solid var(--border); border-radius: 10px; }
table { border-collapse: collapse; width: 100%; min-width: 640px; font-size: .94rem; }
th, td { text-align: left; padding: 9px 12px; border-bottom: 1px solid var(--border); vertical-align: top; }
thead th { background: var(--code-bg); font-weight: 650; white-space: nowrap; position: sticky; top: 0; }
tbody tr:last-child td { border-bottom: 0; }
td.num, td.date { white-space: nowrap; }
td.feat { min-width: 260px; }
td.title { min-width: 240px; }
.badge {
  display: inline-block;
  border-radius: 999px;
  padding: .1em .6em;
  font-size: .82rem;
  font-weight: 650;
  white-space: nowrap;
  border: 1px solid transparent;
}
.badge.ok { color: var(--ok-fg); background: var(--ok-bg); border-color: var(--ok-fg); }
.badge.warn { color: var(--warn-fg); background: var(--warn-bg); border-color: var(--warn-fg); }
.badge.bad { color: var(--bad-fg); background: var(--bad-bg); border-color: var(--bad-fg); }
.badge.info { color: var(--info-fg); background: var(--info-bg); border-color: var(--info-fg); }
.badge.mut { color: var(--mut-fg); background: var(--mut-bg); border-color: var(--mut-fg); }
.tag {
  display: inline-block;
  border-radius: 6px;
  padding: .05em .45em;
  margin-right: .4em;
  font-size: .78rem;
  font-weight: 650;
  color: var(--info-fg);
  background: var(--info-bg);
  border: 1px solid var(--info-bg);
}
.sub { margin: 0 0 16px; }
.sub > h3 { display: flex; align-items: baseline; gap: .5em; flex-wrap: wrap; }
.sub > h3 code { font-size: .95em; }
ul.clean, ol.clean { margin: 0 0 10px; padding-left: 1.15em; }
ul.clean li, ol.clean li { margin-bottom: .35em; }
ul.dash { list-style: none; padding-left: 0; }
ul.dash > li { position: relative; padding-left: 1.1em; margin-bottom: .3em; }
ul.dash > li::before { content: "–"; position: absolute; left: 0; color: var(--muted); }
ul.nope { list-style: none; padding-left: 0; }
ul.nope > li { margin-bottom: .45em; }
.finding { border-left: 4px solid var(--border); padding: 2px 0 2px 14px; margin: 0 0 16px; }
.finding > p:first-child { margin-bottom: .3em; }
.finding .sev { margin-right: .5em; }
.finding.alto { border-left-color: var(--bad-fg); }
.finding.medio { border-left-color: var(--warn-fg); }
.finding.bajo { border-left-color: var(--info-fg); }
.finding.otro { border-left-color: var(--mut-fg); }
.finding .ev { color: var(--muted); font-size: .92rem; }
.pending { margin: 0 0 14px; }
.pending > li { margin-bottom: .8em; }
.pending .what { font-weight: 650; }
.files { list-style: none; padding: 0; margin: 0 0 10px; }
.files li { margin-bottom: .3em; }
.mono-path { font-family: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; font-size: .9em; }
hr.sep { border: 0; border-top: 1px solid var(--border); margin: 18px 0; }
@media (max-width: 640px) {
  .wrap { padding: 16px 10px 40px; }
  section { padding: 16px 14px 18px; border-radius: 10px; }
  h1 { font-size: 1.5rem; }
  .metrics { grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); }
}
@media print {
  body { background: #fff; }
  section { box-shadow: none; break-inside: avoid; }
}
</style>
</head>
<body>
<div class="wrap">
HTML_HEAD

# --- section 1: the header ----------------------------------------------------
{
  printf '<section id="cabecera">\n'
  printf '  <div class="section-head"><h1>El loop de SolidCraft</h1></div>\n'
  printf '  <p class="lead">Un agente que trabaja s&oacute;lo sobre los issues de SolidCraft: elige uno, lo arregla, lo prueba con su propio gate y abre el pull request en el upstream. Esta p&aacute;gina es su hermana en HTML: lo mismo que el <code>RUNBOOK.md</code>, para abrirlo en el navegador.</p>\n'
  printf '  <p class="gen">Generada el %s por <code>bin/docs-html.sh</code> &middot; repo <code>%s</code> &middot; autor <code>%s</code></p>\n' \
    "$(esc "$GEN_STAMP")" "$(esc "$REPO")" "$(esc "$AUTHOR")"
  printf '  <ul class="metrics">\n'
  printf '    <li><span class="k">Vueltas totales</span><span class="v">%s</span></li>\n' "$(esc "$iterations")"
  printf '    <li><span class="k">Fallos</span><span class="v bad">%s</span></li>\n' "$(esc "$failures")"
  printf '    <li><span class="k">PRs abiertos</span><span class="v">%s</span></li>\n' "$(esc "$open_count")"
  printf '    <li><span class="k">Publicados hoy</span><span class="v ok">%s</span></li>\n' "$(esc "$published_today")"
  printf '    <li><span class="k">Disco libre</span><span class="v">%s</span></li>\n' "$(esc "$disk_free_text")"
  printf '  </ul>\n'
  printf '  <p class="note">Disco: %s</p>\n' "$(esc "$disk_detail")"
} >> "$TMP_FILE"

# Slots table: the phase of each slot of the loop.
printf '  <div class="table-wrap">\n  <table>\n    <thead><tr><th>Slot</th><th>Fase</th><th>Issue</th><th>PR</th><th>Revisi&oacute;n</th><th>Gate</th></tr></thead>\n    <tbody>\n' >> "$TMP_FILE"
slots_tsv=""
if [ -f "$STATE_FILE" ] && command -v jq >/dev/null 2>&1; then
  slots_tsv=$(jq -r '
    (.slots // {}) | to_entries | sort_by(.key) | .[]
    | [ (.key|tostring), (.value.phase // "sin datos"), ((.value.issue // "-")|tostring),
        ((.value.pr // "-")|tostring), (.value.review // "-"), (.value.gate_verdict // "-") ]
    | join("\u001f")
  ' "$STATE_FILE" 2>/dev/null)
fi
if [ -n "$slots_tsv" ]; then
  while IFS=$'\x1f' read -r s_key s_phase s_issue s_pr s_review s_gate; do
    [ -z "${s_phase:-}" ] && continue
    case "$s_phase" in
      published) s_cls="ok" ;;
      gating|gated) s_cls="warn" ;;
      failed) s_cls="bad" ;;
      skipped) s_cls="mut" ;;
      *) s_cls="info" ;;
    esac
    printf '      <tr><td>%s</td><td>%s</td><td>#%s</td><td>%s</td><td>%s</td><td>%s</td></tr>\n' \
      "$(esc "$s_key")" "$(badge "$s_cls" "$s_phase")" "$(esc "$s_issue")" \
      "$(esc "$s_pr")" "$(esc "$s_review")" "$(esc "$s_gate")"
  done <<< "$slots_tsv" >> "$TMP_FILE"
else
  printf '      <tr><td colspan="6" class="note">sin datos: no hay slots en <code>state.json</code></td></tr>\n' >> "$TMP_FILE"
fi
printf '    </tbody>\n  </table>\n  </div>\n' >> "$TMP_FILE"
printf '</section>\n' >> "$TMP_FILE"

# --- section 2: what the loop delivered --------------------------------------
{
  printf '<section id="entregas">\n'
  printf '  <div class="section-head"><h2>Lo que entreg&oacute; el loop</h2></div>\n'
  printf '  <p class="lead">Los &uacute;ltimos pull requests nuestros: los que siguen abiertos y los que se han mergeado o cerrado hace poco. Es el coraz&oacute;n de la p&aacute;gina: las features que entregar&aacute;n nuestros PRs recientes.</p>\n'
  printf '  <p class="note">La columna &laquo;Qu&eacute; entrega&raquo; sale literalmente del t&iacute;tulo del PR (sin inventar nada): la etiqueta es el &aacute;rea del cambio y el texto es el t&iacute;tulo sin la referencia al issue. El issue se busca primero en el t&iacute;tulo y, si no est&aacute;, en el cuerpo (<code>Fixes #N</code>).</p>\n'
  printf '  <div class="table-wrap">\n'
  printf '  <table>\n'
  printf '    <thead><tr><th>PR</th><th>T&iacute;tulo</th><th>Issue</th><th>Qu&eacute; entrega</th><th>Estado</th><th>Fecha</th></tr></thead>\n'
  printf '    <tbody>\n'
} >> "$TMP_FILE"

if [ -n "$pr_rows" ]; then
  while IFS=$'\x1f' read -r p_num p_title p_draft p_state p_merged p_closed p_created p_updated; do
    [ -z "${p_num:-}" ] && continue
    p_title="${p_title:-}"
    p_draft="${p_draft:-false}"
    p_state="${p_state:-}"
    p_merged="${p_merged:-}"
    p_closed="${p_closed:-}"
    p_created="${p_created:-}"
    p_updated="${p_updated:-}"

    # The issue the pull request fixes.
    p_issue=$(issue_from_title "$p_title")
    if [ -z "$p_issue" ]; then
      p_issue=$(issue_from_body "$p_num")
    fi

    # The feature, taken from the title.
    p_feature=$(feature_of "$p_title")
    p_area="${p_feature%%|*}"
    p_desc="${p_feature#*|}"
    if [ -z "$p_desc" ]; then
      p_desc="$p_title"
    fi

    # The state of the pull request.
    if [ -n "$p_merged" ]; then
      p_state_label="mergeado"
      p_state_cls="ok"
      p_date="$p_merged"
    elif [ "$p_state" = "CLOSED" ] || [ -n "$p_closed" ]; then
      p_state_label="cerrado"
      p_state_cls="bad"
      p_date="$p_closed"
    elif [ "$p_draft" = "true" ]; then
      p_state_label="draft"
      p_state_cls="warn"
      p_date="$p_updated"
    else
      p_state_label="abierto"
      p_state_cls="info"
      p_date="$p_updated"
    fi
    [ -z "$p_date" ] && p_date="$p_created"

    p_date_txt=$(date_of "$p_date")

    printf '      <tr>'
    printf '<td class="num"><a href="https://github.com/%s/pull/%s">#%s</a></td>' \
      "$(esc "$REPO")" "$(esc "$p_num")" "$(esc "$p_num")"
    printf '<td class="title">%s</td>' "$(esc "$p_title")"
    if [ -n "$p_issue" ]; then
      printf '<td class="num"><a href="https://github.com/%s/issues/%s">#%s</a></td>' \
        "$(esc "$REPO")" "$(esc "$p_issue")" "$(esc "$p_issue")"
    else
      printf '<td class="num note">sin datos</td>'
    fi
    printf '<td class="feat">'
    if [ -n "$p_area" ]; then
      printf '<span class="tag">%s</span>' "$(esc "$p_area")"
    fi
    printf '%s</td>' "$(esc "$p_desc")"
    printf '<td>%s</td>' "$(badge "$p_state_cls" "$p_state_label")"
    printf '<td class="date">%s</td>' "$(esc "$p_date_txt")"
    printf '</tr>\n'
  done <<< "$pr_rows" >> "$TMP_FILE"
else
  printf '      <tr><td colspan="6" class="note">sin datos: GitHub no devolvi&oacute; pull requests (se puede leer la p&aacute;gina sin red).</td></tr>\n' >> "$TMP_FILE"
fi
{
  printf '    </tbody>\n'
  printf '  </table>\n'
  printf '  </div>\n'
  if [ "$pr_rows_count" -gt 0 ]; then
    printf '  <p class="note">%s pull requests listados (abiertos + mergeados recientes), del m&aacute;s nuevo al m&aacute;s viejo.</p>\n' "$pr_rows_count"
  fi
  printf '</section>\n'
} >> "$TMP_FILE"

# --- section 3: what was implemented on 25-10-2026 ----------------------------
cat >> "$TMP_FILE" <<'HTML_SECTION3'
<section id="implementado">
  <div class="section-head"><h2>Lo nuevo implementado (25-10-2026)</h2></div>
  <p class="lead">El trabajo de hoy, en el loop y en su documentaci&oacute;n. Todo verificado en la m&aacute;quina, no sobre el papel.</p>

  <div class="sub">
    <h3><code>bin/gc-disk.sh</code> <span class="badge ok">nuevo</span></h3>
    <p>La limpieza diaria del disco. El disco se llenaba sin que nadie lo notara y nadie lo miraba.</p>
    <p><strong>Borra:</strong></p>
    <ul class="clean">
      <li>las cach&eacute;s <code>incremental</code> de cargo (checkout principal, worktree del gate, worktree de evidencia: ~99 GB),</li>
      <li>los worktrees de las sesiones muertas,</li>
      <li>las ramas locales de PRs ya mergeados o cerrados,</li>
      <li>las copias locales de <code>evidence/*</code>,</li>
      <li>y con <code>--deep</code> los artifacts viejos de nuestras crates (cuesta recompilar: <strong>no</strong> es autom&aacute;tico).</li>
    </ul>
    <p><strong>NUNCA toca:</strong></p>
    <ul class="clean">
      <li>el worktree del gate (nunca se borra un directorio target),</li>
      <li>los <code>deps</code> j&oacute;venes: el tope de 60 GB borra los artifacts m&aacute;s antiguos primero, y nunca uno de menos de 600 s (puede estar en uso),</li>
      <li>las cach&eacute;s <code>release</code> y <code>ci</code> del gate (el gate las reusa y cuesta 89-116 min),</li>
      <li>los worktrees de los issues en vuelo,</li>
      <li>las ramas con un PR abierto,</li>
      <li>las ramas <code>evidence/*</code> DEL FORK (las URLs del cuerpo de los PRs apuntan ah&iacute;),</li>
      <li>el estado, el ledger ni los reportes.</li>
    </ul>
    <p><strong>Sus guardas:</strong></p>
    <ul class="clean">
      <li><code>flock</code>: una limpieza a la vez.</li>
      <li>guardia diario que <strong>NO</strong> avanza si algo se salt&oacute; por m&aacute;quina ocupada (as&iacute; reintenta en la vuelta siguiente).</li>
      <li>un &aacute;rbol de target con un <code>cargo</code> vivo.</li>
      <li>un worktree con trabajo sin commitear (nunca se borra uno sucio).</li>
      <li>una rama con un PR abierto.</li>
    </ul>
  </div>

  <div class="sub">
    <h3><code>bin/supervisor.sh</code></h3>
    <p>Lo llama una vez por vuelta (despu&eacute;s de la rotaci&oacute;n de logs) y su propio guardia diario lo hace correr una vez al d&iacute;a. Adem&aacute;s se reorden&oacute; la precondici&oacute;n de emergencia de disco: ahora borra primero las cach&eacute;s <code>incremental</code> (gratis) y s&oacute;lo despu&eacute;s <code>target/release</code> (12 GB que cuestan un rebuild con LTO).</p>
  </div>

  <div class="sub">
    <h3><code>bin/loop.sh</code></h3>
    <p>El comando <code>loop.sh gc [--dry-run] [--deep]</code> y una l&iacute;nea de disco en <code>loop.sh status</code>.</p>
  </div>

  <div class="sub">
    <h3><code>prompts/</code></h3>
    <ul class="clean">
      <li>El <strong>&laquo;Paso 0&raquo;</strong>: antes de triar, barrer nuestros PRs draft huerfanos y <strong>ADOPTARLOS</strong> (el fix ya est&aacute; commiteado y ning&uacute;n slot los ten&iacute;a).</li>
      <li>El chequeo <strong>&laquo;e)&raquo;</strong> del funnel: el reclamo de un issue lo decide la <strong>TIMELINE</strong> del issue (los cross-references), no el <code>#N</code> del t&iacute;tulo (una menci&oacute;n bajo &laquo;Not in this PR&raquo; tambi&eacute;n cuenta).</li>
      <li>La l&iacute;nea <strong>&laquo;Disk&raquo;</strong> del reporte diario.</li>
    </ul>
  </div>

  <div class="sub">
    <h3><code>RUNBOOK.md</code></h3>
    <p>La secci&oacute;n nueva <strong>&laquo;La limpieza del disco&raquo;</strong> y el chequeo de las dos listas de <code>check-prompt-permissions.py</code>.</p>
  </div>

  <div class="sub">
    <h3>Resultado medido</h3>
    <p>El disco pas&oacute; de <strong>72 % de uso</strong> (135 GB libres) a <strong>51 %</strong> (233 GB libres): <strong>98 GB liberados</strong>, m&aacute;s la automatizaci&oacute;n diaria.</p>
  </div>
</section>
HTML_SECTION3

# --- section 4: gap analysis --------------------------------------------------
cat >> "$TMP_FILE" <<'HTML_SECTION4'
<section id="hallazgos">
  <div class="section-head"><h2>Hallazgos (gap analysis)</h2></div>
  <p class="lead">Lo que se encontr&oacute; revisando c&oacute;mo funciona el loop de verdad, con la severidad y la evidencia de cada punto.</p>

  <div class="finding alto">
    <p><span class="sev badge bad">ALTO</span><strong>upstream</strong> &mdash; el bot de reclamos decide el ganador con los cross-references de la timeline, as&iacute; que un PR que S&Oacute;LO menciona el issue (bajo &laquo;Not in this PR&raquo;) lo bloquea.</p>
    <p class="ev">Evidencia: nuestro <a href="https://github.com/tangency-labs/solidcraft/pull/6661">#6661</a> rechazado por el <a href="https://github.com/tangency-labs/solidcraft/pull/6381">#6381</a> de otro autor.</p>
  </div>

  <div class="finding alto">
    <p><span class="sev badge bad">ALTO</span><strong>upstream</strong> &mdash; el bot no puede entregar su propio mensaje (403 &laquo;Resource not accessible by integration&raquo;).</p>
    <p class="ev">Evidencia: su workflow tiene <code>pull_requests: read</code> y comentar en un PR necesita <code>pull_requests: write</code>; el check queda rojo sin explicaci&oacute;n.</p>
  </div>

  <div class="finding alto">
    <p><span class="sev badge bad">ALTO</span><strong>nuestro</strong> &mdash; el triage no consultaba el estado del reclamo, as&iacute; que sal&iacute;a un PR duplicado; y el token es de s&oacute;lo lectura en el upstream, as&iacute; que un PR duplicado s&oacute;lo lo cierra un humano.</p>
  </div>

  <div class="finding medio">
    <p><span class="sev badge warn">MEDIO</span><strong>nuestro</strong> &mdash; el reporte diario y el libro de aprobaciones estaban desfasados.</p>
    <p class="ev">Evidencia: la CI del fork YA corre (6 PRs nuestros mergeados) &rarr; hay que leer el rollup antes de pedir la aprobaci&oacute;n de un run.</p>
  </div>

  <div class="finding medio">
    <p><span class="sev badge warn">MEDIO</span><strong>nuestro</strong> &mdash; no hab&iacute;a limpieza de disco.</p>
    <p class="ev">Evidencia: 72 % de uso, 94 GB de cach&eacute;s incrementales, 13 worktrees muertos, 28 ramas de PRs cerrados &rarr; resuelto y automatizado.</p>
  </div>

  <div class="finding medio">
    <p><span class="sev badge warn">MEDIO</span><strong>nuestro</strong> &mdash; @@GATING_ROWS@@ de las @@LEDGER_ROWS@@ filas del ledger son <code>gating</code> y s&oacute;lo @@IMPL_ROWS@@ son <code>implemented</code>.</p>
    <p class="ev">Evidencia: el trabajo real es el @@IMPL_PCT@@ % de las vueltas.</p>
  </div>

  <div class="finding bajo">
    <p><span class="sev badge info">BAJO</span><strong>nuestro</strong> &mdash; un worktree con trabajo sin commitear se perd&iacute;a al borrarlo.</p>
    <p class="ev">Evidencia: ahora nunca se borra uno sucio.</p>
  </div>

  <div class="finding otro">
    <p><span class="sev badge mut">NO ES NUESTRO</span>La lane pesada del upstream sigue en <code>SKIPPED</code> sin la etiqueta <code>approved-for-ci</code>, que s&oacute;lo un maintainer puede poner.</p>
  </div>
</section>
HTML_SECTION4

# --- section 5: what only a human can do -------------------------------------
cat >> "$TMP_FILE" <<'HTML_SECTION5'
<section id="pendiente">
  <div class="section-head"><h2>Pendiente para el humano</h2></div>
  <p class="lead">Lo que el loop no puede hacer s&oacute;lo, y lo que hay preparado para que sea r&aacute;pido hacerlo.</p>
  <ol class="clean pending">
    <li>
      <span class="what">Publicar el issue upstream sobre el bot de reclamos.</span>
      <br>Hay un borrador con las citas del 403 y del c&oacute;digo de <code>scripts/claim/claim.js</code>:
      <span class="mono-path">/tmp/opencode/solidcraft-claim-bot-issue.md</span>.
    </li>
    <li>
      <span class="what">Decidir el PR #6661</span> (el del canvas que tapaba la ventana de comandos).
      <br>Notas en <span class="mono-path">/tmp/opencode/solidcraft-pending-writes.md</span> y el dossier en
      <span class="mono-path">/tmp/opencode/pr-6661-dossier.md</span> si existe.
    </li>
    <li>
      <span class="what"><code>bin/dry-run.sh</code> no ensaya la vuelta.</span>
      <br>El chequeo de <code>gh</code> falla en el banco de ensayo y el supervisor sale antes de llegar al ledger.
      Preexistente, sin arreglar.
    </li>
  </ol>
</section>
HTML_SECTION5

# --- section 6: footer --------------------------------------------------------
{
  printf '<section id="pie">\n'
  printf '  <div class="section-head"><h2>Los ficheros del loop</h2></div>\n'
  printf '  <ul class="files">\n'
  printf '    <li><a href="../RUNBOOK.md">RUNBOOK.md</a> &mdash; el runbook en markdown (esta p&aacute;gina es su hermana en HTML)</li>\n'
  printf '    <li><a href="../ledger.md">ledger.md</a> &mdash; una l&iacute;nea por vuelta</li>\n'
  printf '    <li><a href="../config.env">config.env</a> &mdash; cuotas, paths y timeouts</li>\n'
  printf '    <li><a href="../state.json">state.json</a> &mdash; el estado vivo (slots, contadores, PRs)</li>\n'
  printf '    <li><a href="../logs/">logs/</a> &mdash; los logs de las vueltas y de los gates</li>\n'
  printf '    <li><a href="../reports/">reports/</a> &mdash; los reportes diarios</li>\n'
  printf '  </ul>\n'
  printf '  <hr class="sep">\n'
  printf '  <p class="note">Esta p&aacute;gina la genera <code>bin/docs-html.sh</code> (idempotente: se puede volver a correr las veces que haga falta; reescribe el fichero entero, nunca lo a&ntilde;ade). Fecha de generaci&oacute;n: <strong>%s</strong>. Comando exacto: <code>bash %s</code>.</p>\n' \
    "$(esc "$GEN_STAMP")" "$(esc "$SCRIPT_DIR/docs-html.sh")"
  printf '  <p class="note">Los datos salen de <code>state.json</code>, <code>disk.status</code>, del ledger entero (<code>ledger.md</code> y sus trozos comprimidos en <code>ledger/</code>) y de <code>gh pr list</code> contra <code>%s</code>. Sin JavaScript, sin recursos externos: se abre y se lee sin conexi&oacute;n.</p>\n' "$(esc "$REPO")"
  printf '</section>\n'
  printf '</div>\n'
  printf '</body>\n'
  printf '</html>\n'
} >> "$TMP_FILE"

# --- publish ------------------------------------------------------------------
# The numbers of the findings are LIVE: they come from the ledger, not from
# the day the text was written (a doc that lies about the state is worse than
# no doc).
LEDGER_ROWS=0
GATING_ROWS=0
IMPL_ROWS=0
if ledger_has_files; then
  LEDGER_ROWS="$(ledger_count '^\| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \| [0-9]+ \| [a-z]+ \|')"
  GATING_ROWS="$(ledger_count '^\| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \| [0-9]+ \| gating \|')"
  IMPL_ROWS="$(ledger_count '^\| [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z \| [0-9]+ \| implemented \|')"
fi
case "$LEDGER_ROWS" in ''|*[!0-9]*) LEDGER_ROWS=0 ;; esac
case "$GATING_ROWS" in ''|*[!0-9]*) GATING_ROWS=0 ;; esac
case "$IMPL_ROWS" in ''|*[!0-9]*) IMPL_ROWS=0 ;; esac
IMPL_PCT=0
if [ "$LEDGER_ROWS" -gt 0 ]; then
  IMPL_PCT=$(( (IMPL_ROWS * 100 + LEDGER_ROWS / 2) / LEDGER_ROWS ))
fi
sed -i \
  -e "s/@@GATING_ROWS@@/$GATING_ROWS/g" \
  -e "s/@@LEDGER_ROWS@@/$LEDGER_ROWS/g" \
  -e "s/@@IMPL_ROWS@@/$IMPL_ROWS/g" \
  -e "s/@@IMPL_PCT@@/$IMPL_PCT/g" \
  "$TMP_FILE" 2>/dev/null || true

if [ "$DRY_RUN" = "1" ]; then
  printf 'Ensayo: se generaria %s (%s bytes, %s filas de PRs). No se escribe nada.\n' \
    "$OUT_FILE" "$(wc -c < "$TMP_FILE" | tr -d ' ')" "$pr_rows_count"
  exit 0
fi

if ! mv -f "$TMP_FILE" "$OUT_FILE" 2>/dev/null; then
  printf 'No se pudo escribir %s: permisos denegados.\n' "$OUT_FILE" >&2
  exit 1
fi
TMP_FILE=""
# mktemp creates the file with mode 600; the page is meant to be read.
chmod 644 "$OUT_FILE" 2>/dev/null

# --- publish to Vercel --------------------------------------------------------
# The page is a static site: the directory has the index.html that Vercel
# serves at the root. The deploy uses the session of the CLI (the account of
# the human), never a token of the loop.
if [ "$DEPLOY" -eq 1 ]; then
  if ! command -v vercel >/dev/null 2>&1; then
    printf 'vercel no esta instalado: la pagina se wrote pero no se publico\n' >&2
  else
    printf 'Publicando en Vercel (proyecto %s)...\n' "$VERCEL_PROJECT"
    deploy_out="$( cd "$DOCS_DIR" && vercel --prod --yes --name "$VERCEL_PROJECT" 2>&1 )"
    deploy_rc=$?
    url="$(printf '%s\n' "$deploy_out" | sed -n 's/.*Production URL: \([^ ]*\) .*/\1/p; s/.*"url": "\([^"]*\)".*/\1/p' | head -1)"
    if [ "$deploy_rc" -eq 0 ]; then
      printf 'Publicada: %s\n' "${url:-https://$VERCEL_PROJECT.vercel.app}"
    else
      printf '%s\n' "$deploy_out" | tail -12
      printf 'vercel no pudo publicar: la pagina quedo escrita en %s\n' "$OUT_FILE" >&2
    fi
  fi
fi

printf 'Documentacion escrita: %s (%s bytes, %s filas de PRs, %s PRs abiertos, disco: %s).\n' \
  "$OUT_FILE" "$(wc -c < "$OUT_FILE" | tr -d ' ')" "$pr_rows_count" "$open_count" "$disk_label"
exit 0
