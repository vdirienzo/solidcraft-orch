#!/usr/bin/env python3
# ---------------------------------------------------------------------------
# gh_snapshot.py - UNA foto de GitHub: los issues abiertos y los PRs abiertos
# del upstream, en un archivo.
#
# POR QUE EXISTE (2026-11-21): next-issue.py leia solo `gh issue list --limit
# 150` (el upstream tiene ~6800 issues abiertos: el selector veia el 2%), y
# cada llamada a claim-verify.sh bajaba `gh pr list --limit 2000` con los
# bodies (~11 paginas de GraphQL). Se pagaban entre 25 y 50 paginas por slot y
# nada se reusaba. Esta foto se baja UNA vez, con GraphQL paginado, y la leen
# next-issue.py, issue-card.py y claim-verify.sh --snapshot.
#
# DONDE QUEDA: $ORCH_DIR/state/cache/gh-snapshot.json (o GH_SNAPSHOT).
# NO en state/gh-snapshot.json: bin/merge-state.sh trata cada state/*.json que
# es un objeto como un CONCEPTO del estado, y uno que no esta en el manifiesto
# lo hace morir ("archivo de concepto sin grupo en el manifiesto", rc=2,
# medido el 2026-11-21). Un subdirectorio no es un concepto.
#
# LO QUE GARANTIZA:
#   - la escritura es atomica (tmp + fsync + rename): un lector nunca ve media
#     foto;
#   - una foto INCOMPLETA no se escribe: si GitHub falla (despues de los
#     reintentos), o si lo bajado no cuadra con el totalCount, sale 2 y la foto
#     anterior queda como estaba. Los lectores exigen `complete: true`;
#   - --max-age-min N reusa una foto completa de menos de N minutos sin tocar
#     GitHub.
#
# COMO BAJA (medido el 2026-11-21): una pagina de 100 issues con sus labels,
# asignados y los ultimos 5 comentarios tarda ~2,4 s y cuesta 3 puntos; una de
# 100 PRs ~3,8 s y 1 punto. Cada conexion se baja con DOS cursores en
# paralelo, uno desde el mas viejo (ASC) y otro desde el mas nuevo (DESC), que
# paran cuando se cruzan: la mitad del tiempo, el mismo costo. El "ultimo
# push" de un PR (commits(last:1)) NO va: subia la pagina de 2,7 s a 7,4 s.
#
# USO:
#   python3 bin/gh_snapshot.py                    # baja la foto y dice donde quedo
#   python3 bin/gh_snapshot.py --max-age-min 15   # reusa la de menos de 15 min
#   python3 bin/gh_snapshot.py --out FILE --files # otra ruta; con los archivos de cada PR
#
# CODIGOS DE SALIDA:
#   0   la foto esta en el archivo (la ruta, en el stdout)
#   2   GitHub no se pudo leer entero: NO se escribio nada
#   64  error de uso
# ---------------------------------------------------------------------------
import fcntl
import json
import os
import subprocess
import sys
import threading
import time

VERSION = 1
REPO = os.environ.get("UPSTREAM_REPO", "tangency-labs/solidcraft")
ORCH_DIR = os.environ.get("ORCH_DIR") or os.path.expanduser("~/.local/share/solidcraft-orch")
# The gh of the machine, or the one of a test (README rule 4: the stub lives
# OUTSIDE the PATH and is chosen with GH_BIN).
GH_BIN = os.environ.get("GH_BIN") or "gh"
PAGE_SIZE = 100
MIN_PAGE_SIZE = 25
ATTEMPTS = 4
# Lo que puede cambiar el totalCount mientras se baja la foto (issues que se
# abren o se cierran en ~90 s). Mas que esto es una foto con agujeros.
TOLERANCE = 10

ISSUE_FIELDS = """
        number title body createdAt updatedAt
        author { login }
        labels(first: 30) { nodes { name } }
        assignees(first: 10) { nodes { login } }
        comments(last: 5) { totalCount nodes { author { login } authorAssociation body createdAt } }
"""
PR_FIELDS = """
        number title body isDraft headRefName baseRefName createdAt updatedAt
        author { login }
        labels(first: 30) { nodes { name } }
        additions deletions changedFiles
"""
PR_FILES = "        files(first: 100) { nodes { path } }\n"

# The FULL photo: every OPEN node, by creation date, from one end or the other.
QUERY_FULL = """
query($owner: String!, $name: String!, $first: Int!, $after: String, $dir: OrderDirection!) {
  rateLimit { cost remaining resetAt }
  repository(owner: $owner, name: $name) {
    %(conn)s(states: OPEN, first: $first, after: $after, orderBy: {field: CREATED_AT, direction: $dir}) {
      totalCount
      pageInfo { hasNextPage endCursor }
      nodes {
%(fields)s      }
    }
  }
}
"""
# The REFRESH of a photo: what CHANGED since it was taken (opened, edited,
# labelled, assigned, commented, closed), newest change first, with the count
# of the open ones to check that the merge has no holes. The issues filter by
# `since` on the server; the pull requests have no such filter and are read
# until the first one that did not change.
QUERY_CHANGED = """
query($owner: String!, $name: String!, $first: Int!, $after: String%(since_var)s) {
  rateLimit { cost remaining resetAt }
  repository(owner: $owner, name: $name) {
    open: %(conn)s(states: OPEN) { totalCount }
    %(conn)s(states: %(states)s, first: $first, after: $after%(filter)s, orderBy: {field: UPDATED_AT, direction: DESC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        state
%(fields)s      }
    }
  }
}
"""
# A full photo every so often even when the refreshes work: an issue that is
# deleted or transferred changes nothing that a refresh can see.
FULL_EVERY_MIN = float(os.environ.get("GH_SNAPSHOT_FULL_EVERY_MIN", "360"))
# What a refresh reads BEFORE the start of the previous photo: the clocks of
# this machine and of GitHub are not the same clock.
SINCE_MARGIN_S = 300


class SnapshotError(Exception):
    """GitHub could not be read entirely: the snapshot is not written."""


def default_path():
    return os.environ.get("GH_SNAPSHOT") or os.path.join(ORCH_DIR, "state", "cache", "gh-snapshot.json")


def log(msg):
    print(f"gh_snapshot: {msg}", file=sys.stderr)


# --- reading -----------------------------------------------------------------


def load(path=None, max_age_min=None, repo=None):
    """(snapshot, None) when the file is a COMPLETE snapshot (and fresh, when
    max_age_min is given); (None, reason) otherwise. Never raises."""
    path = path or default_path()
    try:
        with open(path, encoding="utf-8") as fh:
            snap = json.load(fh)
    except FileNotFoundError:
        return None, f"no hay foto en {path}"
    except (OSError, ValueError) as exc:
        return None, f"la foto {path} no se puede leer ({exc.__class__.__name__})"
    if not isinstance(snap, dict) or snap.get("version") != VERSION:
        return None, f"la foto {path} no es de la version {VERSION}"
    if snap.get("complete") is not True:
        return None, f"la foto {path} no esta completa"
    if not isinstance(snap.get("issues"), list) or not isinstance(snap.get("prs"), list):
        return None, f"la foto {path} no tiene las listas de issues y PRs"
    if repo and str(snap.get("repo", "")).lower() != repo.lower():
        return None, f"la foto {path} es de {snap.get('repo')}, no de {repo}"
    age = age_min(snap)
    if age is None:
        return None, f"la foto {path} no dice cuando se saco"
    if max_age_min is not None and age > float(max_age_min):
        return None, f"la foto {path} tiene {age:.0f} min (el tope es {max_age_min})"
    return snap, None


def age_min(snap):
    try:
        return max(0.0, (time.time() - float(snap["generated_epoch"])) / 60.0)
    except (KeyError, TypeError, ValueError):
        return None


# --- fetching ----------------------------------------------------------------


class Stats:
    def __init__(self):
        self.lock = threading.Lock()
        self.pages = 0
        self.cost = 0
        self.remaining = None

    def add(self, rate):
        with self.lock:
            self.pages += 1
            if isinstance(rate, dict):
                self.cost += int(rate.get("cost") or 0)
                if rate.get("remaining") is not None:
                    rem = int(rate["remaining"])
                    self.remaining = rem if self.remaining is None else min(self.remaining, rem)


def _query(query, variables, timeout):
    """One GraphQL call through gh: (repository, rateLimit). Raises."""
    cmd = [GH_BIN, "api", "graphql", "-f", "query=" + query]
    for key, value in variables.items():
        if value is None:
            continue
        # -F types the value (the page size is an Int); -f keeps a string.
        cmd += ["-F" if isinstance(value, int) else "-f", f"{key}={value}"]
    done = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    if done.returncode != 0:
        raise SnapshotError(f"gh rc={done.returncode}: {(done.stderr or done.stdout).strip()[:200]}")
    data = json.loads(done.stdout)
    if not isinstance(data, dict) or data.get("errors"):
        raise SnapshotError(f"GraphQL respondio con errores: {str(data.get('errors') if isinstance(data, dict) else data)[:200]}")
    body = data.get("data") or {}
    repo = body.get("repository")
    if not isinstance(repo, dict):
        raise SnapshotError("la respuesta no trae el repositorio")
    return repo, body.get("rateLimit")


def _fetch(query, variables, conn, state, deadline, stats, label):
    """One page, with retries: (repository, page). A page that fails is
    retried smaller: the big pages are the ones GitHub answers with a 502."""
    sleep = float(os.environ.get("GH_SNAPSHOT_RETRY_SLEEP", "2"))
    last = None
    for attempt in range(ATTEMPTS):
        left = deadline - time.time()
        if left <= 0:
            raise SnapshotError("se acabo el tiempo de la foto")
        try:
            repo, rate = _query(query, dict(variables, first=state["first"]), min(120, left))
            page = repo.get(conn)
            if not isinstance(page, dict) or not isinstance(page.get("nodes"), list):
                raise SnapshotError(f"la respuesta no trae {conn}")
            stats.add(rate)
            return repo, page
        except (SnapshotError, ValueError, OSError, subprocess.SubprocessError) as exc:
            last = exc
            state["first"] = max(MIN_PAGE_SIZE, state["first"] // 2)
            if attempt + 1 < ATTEMPTS:
                time.sleep(sleep * (attempt + 1))
    raise SnapshotError(f"{label}: {last}")


def fetch_connection(conn, fields, repo, deadline, stats):
    """Every OPEN node of the connection, by number. Two cursors, one from each
    end, that stop when they meet: each one covers a CONTIGUOUS run of the
    order, so the moment they share one node the two runs cover all of it."""
    owner, name = repo.split("/", 1)
    query = QUERY_FULL % {"conn": conn, "fields": fields}
    seen = {}
    lock = threading.Lock()
    done = threading.Event()
    errors = []
    totals = []

    def take(page, direction):
        with lock:
            totals.append(int(page.get("totalCount") or 0))
            overlap = False
            for node in page["nodes"]:
                if not isinstance(node, dict) or not isinstance(node.get("number"), int):
                    continue
                prev = seen.get(node["number"])
                if prev is not None and prev[0] != direction:
                    overlap = True
                seen[node["number"]] = (direction, node)
            if overlap or not (page.get("pageInfo") or {}).get("hasNextPage"):
                done.set()

    def page_of(direction, after, state):
        _, page = _fetch(query, {"owner": owner, "name": name, "after": after, "dir": direction},
                         conn, state, deadline, stats, f"{conn} {direction}")
        return page

    def stream(direction, after=None):
        state = {"first": PAGE_SIZE}
        try:
            while not done.is_set():
                page = page_of(direction, after, state)
                take(page, direction)
                after = (page.get("pageInfo") or {}).get("endCursor")
                if not after:
                    done.set()
        except Exception as exc:  # noqa: BLE001 - a thread must report, not die
            errors.append(exc)
            done.set()

    # The first page alone: a small connection fits in it, and the second
    # cursor would only download it again.
    first = page_of("ASC", None, {"first": PAGE_SIZE})
    take(first, "ASC")
    if not done.is_set():
        threads = [
            threading.Thread(target=stream, args=("ASC", (first.get("pageInfo") or {}).get("endCursor")), daemon=True),
            threading.Thread(target=stream, args=("DESC",), daemon=True),
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
    if errors:
        raise SnapshotError(str(errors[0]))
    nodes = [node for _, node in seen.values()]
    total = totals[-1] if totals else 0
    if abs(len(nodes) - total) > TOLERANCE:
        raise SnapshotError(f"{conn}: se bajaron {len(nodes)} de {total}: la foto tendria agujeros")
    return nodes, total


def fetch_changed(conn, fields, repo, since_iso, deadline, stats):
    """(changed nodes, number of open ones now): every node of the connection
    whose updatedAt is at or after since_iso, open or not."""
    owner, name = repo.split("/", 1)
    if conn == "issues":
        query = QUERY_CHANGED % {"conn": conn, "fields": fields, "states": "[OPEN, CLOSED]",
                                 "since_var": ", $since: DateTime!", "filter": ", filterBy: {since: $since}"}
        variables = {"owner": owner, "name": name, "since": since_iso}
    else:
        query = QUERY_CHANGED % {"conn": conn, "fields": fields, "states": "[OPEN, CLOSED, MERGED]",
                                 "since_var": "", "filter": ""}
        variables = {"owner": owner, "name": name}
    state = {"first": PAGE_SIZE}
    after = None
    changed = []
    open_total = None
    while True:
        repo_data, page = _fetch(query, dict(variables, after=after), conn, state, deadline, stats, f"{conn} cambios")
        open_total = int(((repo_data.get("open") or {}).get("totalCount")) or 0)
        older = False
        for node in page["nodes"]:
            if not isinstance(node, dict) or not isinstance(node.get("number"), int):
                continue
            if (node.get("updatedAt") or "") < since_iso:
                older = True
                continue
            changed.append(node)
        after = (page.get("pageInfo") or {}).get("endCursor")
        if older or not after or not (page.get("pageInfo") or {}).get("hasNextPage"):
            return changed, open_total


def _login(actor):
    return (actor.get("login") or "") if isinstance(actor, dict) else ""


def _nodes(conn):
    return [n for n in ((conn or {}).get("nodes") or []) if isinstance(n, dict)]


def norm_issue(n):
    """The shapes of `gh issue list --json`: the filters of next-issue.py
    read labels[].name, assignees[].login and comments[].body."""
    comments = n.get("comments") or {}
    return {
        "number": n["number"],
        "title": n.get("title") or "",
        "body": n.get("body") or "",
        "author": {"login": _login(n.get("author"))},
        "createdAt": n.get("createdAt") or "",
        "updatedAt": n.get("updatedAt") or "",
        "labels": [{"name": l.get("name") or ""} for l in _nodes(n.get("labels"))],
        "assignees": [{"login": a.get("login") or ""} for a in _nodes(n.get("assignees"))],
        "comments": [
            {"author": {"login": _login(c.get("author"))}, "association": c.get("authorAssociation") or "", "body": c.get("body") or "", "createdAt": c.get("createdAt") or ""}
            for c in _nodes(comments)
        ],
        "commentsCount": int(comments.get("totalCount") or 0) if isinstance(comments, dict) else 0,
    }


def norm_pr(n):
    """The shapes of `gh pr list --json`: claim_rule.py reads number, title,
    body and author.login."""
    out = {
        "number": n["number"],
        "title": n.get("title") or "",
        "body": n.get("body") or "",
        "author": {"login": _login(n.get("author"))},
        "isDraft": bool(n.get("isDraft")),
        "headRefName": n.get("headRefName") or "",
        "baseRefName": n.get("baseRefName") or "",
        "createdAt": n.get("createdAt") or "",
        "updatedAt": n.get("updatedAt") or "",
        "labels": [{"name": l.get("name") or ""} for l in _nodes(n.get("labels"))],
        "additions": int(n.get("additions") or 0),
        "deletions": int(n.get("deletions") or 0),
        "changedFiles": int(n.get("changedFiles") or 0),
    }
    if "files" in n:
        out["files"] = [f.get("path") or "" for f in _nodes(n.get("files"))]
    return out


def _iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def _fields(files):
    return ISSUE_FIELDS, PR_FIELDS + (PR_FILES if files else "")


def _parallel(jobs):
    """Run the jobs ({key: callable}) at once; their results, or raise the
    first error."""
    results = {}
    errors = []

    def run(key, fn):
        try:
            results[key] = fn()
        except Exception as exc:  # noqa: BLE001 - a thread must report, not die
            errors.append(exc)

    threads = [threading.Thread(target=run, args=(k, fn), daemon=True) for k, fn in jobs.items()]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    if errors:
        raise SnapshotError(str(errors[0]))
    return results


def _wrap(repo, files, start, stats, issues, issues_total, prs, prs_total, mode, full_epoch):
    now = time.time()
    return {
        "version": VERSION,
        "complete": True,
        "repo": repo,
        "mode": mode,
        "started_epoch": start,
        "generated_at": _iso(now),
        "generated_epoch": now,
        "full_epoch": full_epoch,
        "duration_s": round(now - start, 1),
        "api": {"pages": stats.pages, "cost": stats.cost, "remaining": stats.remaining},
        "counts": {"issues": len(issues), "issues_total": issues_total, "prs": len(prs), "prs_total": prs_total},
        "with_files": bool(files),
        "issues": sorted(issues, key=lambda i: -i["number"]),
        "prs": sorted(prs, key=lambda p: p["number"]),
    }


def build(repo=REPO, files=False, timeout_s=600):
    """The whole snapshot, in memory. Raises SnapshotError."""
    if "/" not in repo:
        raise SnapshotError(f"el repo tiene que ser owner/nombre: {repo!r}")
    start = time.time()
    deadline = start + timeout_s
    stats = Stats()
    ifields, pfields = _fields(files)
    got = _parallel({
        "issues": lambda: fetch_connection("issues", ifields, repo, deadline, stats),
        "prs": lambda: fetch_connection("pullRequests", pfields, repo, deadline, stats),
    })
    issues, issues_total = got["issues"]
    prs, prs_total = got["prs"]
    return _wrap(repo, files, start, stats, [norm_issue(n) for n in issues], issues_total,
                 [norm_pr(n) for n in prs], prs_total, "full", start)


def refresh(prev, timeout_s=600):
    """The previous snapshot plus what changed since it was STARTED (an issue
    edited while the previous one was being downloaded may have been read
    before the edit). Raises SnapshotError when the merge does not add up:
    the caller then takes a full one."""
    repo = prev["repo"]
    files = bool(prev.get("with_files"))
    start = time.time()
    deadline = start + timeout_s
    stats = Stats()
    since = _iso(float(prev.get("started_epoch") or prev["generated_epoch"]) - SINCE_MARGIN_S)
    ifields, pfields = _fields(files)
    got = _parallel({
        "issues": lambda: fetch_changed("issues", ifields, repo, since, deadline, stats),
        "prs": lambda: fetch_changed("pullRequests", pfields, repo, since, deadline, stats),
    })
    issues = {i["number"]: i for i in prev["issues"]}
    for node in got["issues"][0]:
        if node.get("state") == "OPEN":
            issues[node["number"]] = norm_issue(node)
        else:
            issues.pop(node["number"], None)
    prs = {p["number"]: p for p in prev["prs"]}
    for node in got["prs"][0]:
        if node.get("state") == "OPEN":
            prs[node["number"]] = norm_pr(node)
        else:
            prs.pop(node["number"], None)
    issues_total, prs_total = got["issues"][1], got["prs"][1]
    # A refresh is exact or it is not used: what it cannot see (a deleted or
    # transferred issue) shows up as a count that does not match.
    if len(issues) != issues_total or len(prs) != prs_total:
        raise SnapshotError(
            f"el refresco no cuadra ({len(issues)} issues de {issues_total}, {len(prs)} PRs de {prs_total})"
        )
    return _wrap(repo, files, start, stats, list(issues.values()), issues_total, list(prs.values()), prs_total,
                 "incremental", float(prev.get("full_epoch") or prev["generated_epoch"]))


def write_atomic(path, snap):
    d = os.path.dirname(os.path.abspath(path))
    os.makedirs(d, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(snap, fh, ensure_ascii=False, separators=(",", ":"))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def _usable(snap, files):
    return snap is not None and (snap.get("with_files") or not files)


def ensure(path=None, max_age_min=None, repo=REPO, files=False, timeout_s=600, full=False):
    """(snapshot, reused, None) or (None, False, error).

    Reuses a complete snapshot younger than max_age_min. Otherwise it
    REFRESHES the previous one (only what changed: a few pages instead of
    ~80) when that one is complete and its last full download is younger
    than FULL_EVERY_MIN, and downloads a full one when it is not, or when the
    refresh does not add up. Two callers at once download it once: the second
    waits on the lock and reuses it."""
    path = path or default_path()
    if max_age_min is not None:
        snap, _ = load(path, max_age_min, repo)
        if _usable(snap, files):
            return snap, True, None
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path + ".lock", "w", encoding="utf-8") as lockfh:
        fcntl.flock(lockfh, fcntl.LOCK_EX)
        if max_age_min is not None:
            snap, _ = load(path, max_age_min, repo)
            if _usable(snap, files):
                return snap, True, None
        snap = None
        prev, _ = load(path, None, repo)
        if not full and _usable(prev, files):
            try:
                full_age_min = (time.time() - float(prev.get("full_epoch") or 0)) / 60.0
            except (TypeError, ValueError):
                full_age_min = FULL_EVERY_MIN + 1
            if full_age_min <= FULL_EVERY_MIN:
                try:
                    snap = refresh(prev, timeout_s)
                except (SnapshotError, KeyError, TypeError, ValueError) as exc:
                    log(f"el refresco no sirvio, se baja la foto entera ({exc})")
        if snap is None:
            try:
                snap = build(repo, files, timeout_s)
            except SnapshotError as exc:
                return None, False, str(exc)
        try:
            write_atomic(path, snap)
        except OSError as exc:
            return None, False, f"no se pudo escribir {path}: {exc}"
        return snap, False, None


def summary(snap, reused):
    c = snap.get("counts") or {}
    api = snap.get("api") or {}
    if reused:
        return f"foto reusada ({age_min(snap):.0f} min): {c.get('issues')} issues, {c.get('prs')} PRs"
    return (
        f"{c.get('issues')} issues y {c.get('prs')} PRs abiertos en {snap.get('duration_s')} s "
        f"({'refresco' if snap.get('mode') == 'incremental' else 'foto entera'}), "
        f"{api.get('pages')} paginas, costo {api.get('cost')} puntos (quedan {api.get('remaining')})"
    )


def main(argv):
    out = None
    max_age = None
    files = False
    repo = REPO
    timeout_s = 600
    full = False
    i = 0
    try:
        while i < len(argv):
            a = argv[i]
            if a == "--out":
                out = argv[i + 1]
                i += 1
            elif a.startswith("--out="):
                out = a.split("=", 1)[1]
            elif a == "--max-age-min":
                max_age = float(argv[i + 1])
                i += 1
            elif a.startswith("--max-age-min="):
                max_age = float(a.split("=", 1)[1])
            elif a == "--repo":
                repo = argv[i + 1]
                i += 1
            elif a == "--timeout-s":
                timeout_s = float(argv[i + 1])
                i += 1
            elif a == "--files":
                files = True
            elif a == "--full":
                full = True
            elif a in ("-h", "--help"):
                print("uso: gh_snapshot.py [--out FILE] [--max-age-min N] [--files] [--repo owner/name] [--timeout-s S] [--full]")
                return 0
            else:
                raise ValueError(a)
            i += 1
    except (IndexError, ValueError) as exc:
        print(f"gh_snapshot: uso: gh_snapshot.py [--out FILE] [--max-age-min N] [--files] [--repo owner/name] ({exc})", file=sys.stderr)
        return 64
    path = out or default_path()
    snap, reused, err = ensure(path, max_age, repo, files, timeout_s, full)
    if snap is None:
        log(f"GitHub no se pudo leer entero: NO se escribio la foto ({err})")
        return 2
    log(summary(snap, reused))
    print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
