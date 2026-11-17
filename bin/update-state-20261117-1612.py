#!/usr/bin/env python3
"""Update the orchestrator state for wave 2026-11-17 16:12 (-03).

Edits state.json in place (atomic replace), then the caller runs
merge-state.sh --split to adopt it into state/ and --check to verify.
"""
import json
import os
import tempfile
ORCH_DIR = os.environ.get("ORCH_DIR", "/home/user/.local/share/solidcraft-orch")
WORKTREES_DIR = os.environ.get("WORKTREES_DIR", "/home/user/solidcraft-wt")

from datetime import datetime, timezone

P = os.path.join(ORCH_DIR, "state.json")
NOW = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

with open(P) as f:
    s = json.load(f)

slots = s.setdefault("slots", {})

slots["18075"] = {
    "issue": 18075,
    "status": "pr_open_draft",
    "pr": 18550,
    "pr_title": "Sketch: a fillet or a chamfer reaches the corner symmetric to the one it cuts (#18075)",
    "pr_draft": True,
    "branch": "spike/issue-18075",
    "worktree": "/home/user/solidcraft-wt/issue-18075",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-18075",
    "lock_owner": "wave-20261117-1612-impl",
    "head": "dec975047e0e5a4ca0b063b069fb50919cb37744",
    "agent_finished": True,
    "delegation": "wave-20261117-1612: corredor del loop (wave wave-20261116-2107-impl, que murio) + rescate del orquestador",
    "result": (
        "PR #18550 ABIERTO EN DRAFT (head dec975047, base main, MERGEABLE). El trabajo lo dejo la wave "
        "wave-20261116-2107-impl: el fix y su test RED ya estaban commiteados (c026d5aae, 2 archivos, "
        "crates/engine/src/cmd/sketch_modify.rs + sketch_modify_tests.rs, +223) pero SIN PR y con el gate "
        "interrumpido (GATE_EXIT=143). El orquestador rebaseo lineal sobre origin/main (c026d5aae -> "
        "dec975047, merge-tree rc=0), pusheo al fork con --force-with-lease y publico el draft con "
        "bin/publish-pr.sh (claim-verify rc=0, sin duplicado por parche, body con 'Fixes #18075' y "
        "'Changes a default: no' validado con pr-defaults-line.sh: checked 1 missing 0). RED y GREEN "
        "ya medidos: 3 tests del area (a_fillet_reaches_the_corner_symmetric_to_the_one_it_rounds, "
        "a_chamfer_reaches_the_corner_symmetric_to_the_one_it_cuts, "
        "a_fillet_reaches_the_mirrored_corner_of_a_mirrored_copy) fallan sin el fix (EXIT=100) y pasan "
        "con el (3 passed / 0 failed, EXIT=0). Gate reencolado (dec975047)."
    ),
    "gate": "encolado en la cola de gates (dec975047); el gate local anterior murio con SIGTERM (143)",
}

slots["18260"] = {
    "issue": 18260,
    "status": "pr_open_draft",
    "pr": 18528,
    "pr_title": "Sketch: a sketch moved onto a parallel midplane keeps its world place and moves straight up (#18260)",
    "pr_draft": True,
    "branch": "fix/issue-18260-midplane-world-frame",
    "worktree": "/home/user/solidcraft-wt/issue-18260",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-18260",
    "lock_owner": "wave-20261117-1612-impl",
    "head": "3ffec8ca5c343b75a3d5b54fcba6d01487ae36ea",
    "agent_finished": True,
    "result": (
        "PR #18528 ABIERTO en draft (head 3ffec8ca5, MERGEABLE/CLEAN, 12 checks pass + 2 pending). "
        "Gate local VERDE EFECTIVO: scope.effective.verdict = VERDE-SCOPE NEW_FAILURES=0 "
        "PREEXISTING_FAILURES=3 (los tres son fallos de origin/main: corpus_designs_name_alike, "
        "chord_and_variable_fillets e inserting_variable_fillet_control_preserves, los tres listados "
        "en tests/KNOWN_FAILING_TESTS de origin/main). El veredicto CRUDO sale ROJO-SCOPE por esos "
        "mismos 3 preexistentes (la baseline local del loop esta mas vieja que el KNOWN_FAILING_TESTS "
        "del upstream: 39 lineas vs 13 del upstream). El pipeline lo sube a ready solo cuando el CI de "
        "GitHub este verde."
    ),
    "gate": "VERDE-SCOPE (efectivo) NEW_FAILURES=0 PREEXISTING=3 CHECKS=fmt:ok|layers:ok|clippy:ok|check:ok SHA=3ffec8ca5",
}

slots["18364"] = {
    "issue": 18364,
    "status": "running",
    "pr": None,
    "branch": "spike/issue-18364",
    "worktree": "/home/user/solidcraft-wt/issue-18364",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-18364",
    "lock_owner": "wave-20261117-1612-impl",
    "delegation": "wave-20261117-1612: corredor del loop (agent-issue.sh 18364 --timeout 30 --model opencode/deepseek-v4.1-flash-free)",
    "log": "/home/user/.local/share/solidcraft-orch/logs/18364-wave.log",
    "model": "opencode/deepseek-v4.1-flash-free",
    "agent_finished": False,
    "result": "DESPACHADO: el bug es de solver de sketch (un arco tangente a las dos lineas de un angulo cambia de angulo interior a exterior cuando se dimensiona la arista). claim-verify rc=0, claim-race VERDICT=OK/free, lock tomado. El agente esta leyendo crates/sketch/src.",
}

slots["18445"] = {
    "issue": 18445,
    "status": "running",
    "pr": None,
    "branch": "spike/issue-18445",
    "worktree": "/home/user/solidcraft-wt/issue-18445",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-18445",
    "lock_owner": "wave-20261117-1612-impl",
    "delegation": "wave-20261117-1612: corredor del loop (agent-issue.sh 18445 --timeout 30 --model opencode/glm-5.3-flash-free)",
    "log": "/home/user/.local/share/solidcraft-orch/logs/18445-wave.log",
    "model": "opencode/glm-5.3-flash-free",
    "agent_finished": False,
    "result": "DESPACHADO: el icono de la restriccion Concentricity en la barra de herramientas es mas grande que los demas (y el de Distance tambien). claim-verify rc=0, claim-race VERDICT=OK/free, lock tomado. El agente ya escribio el fix y esta verificando visualmente con capturas.",
}

# PR #18192 was closed by us (no-op, the bug is fixed upstream by #17921); #18035 was closed by the
# maintainer as covered by #18014/#18148; #18189 was merged upstream. Record the truth.
slots["17881"] = {
    "issue": 17881,
    "status": "abandoned_superseded_upstream",
    "pr": 18192,
    "pr_state": "CLOSED",
    "lock_owner": None,
    "agent_finished": True,
    "result": (
        "PR #18192 CERRADO por nosotros con la evidencia pedida. El mantenedor (bherbruck, "
        "2026-11-17T02:19Z) pidio una captura antes/despues de Home con el Browser docked a la "
        "izquierda; la medimos y la publicamos. La medicion dijo otra cosa: el fix de la rama es un "
        "no-op en el escritorio y el bug ya esta arreglado en main por #17921 (merge 3f886e460). "
        "Se cerro el PR y la rama queda publicada en el fork (fix/issue-17881-home-occluding-panels) "
        "por si algo de ella se quiere despues; la evidencia queda en evidence/issue-17881-home."
    ),
}

slots["17890"] = {
    "issue": 17890,
    "status": "closed_upstream_covered",
    "pr": 18035,
    "pr_state": "CLOSED",
    "lock_owner": None,
    "agent_finished": True,
    "result": (
        "PR #18035 CERRADO por el mantenedor (bherbruck, 2026-11-16T23:51Z) como cubierto: el mismo "
        "issue lo arreglaron #18014 y #18148, que mergearon ese dia. Our branch queda en el fork."
    ),
}

slots["17852"] = {
    "issue": 17852,
    "status": "merged_upstream",
    "pr": 18189,
    "pr_state": "MERGED",
    "merge_commit": "b59ea6a03",
    "lock_owner": None,
    "agent_finished": True,
    "result": "PR #18189 MERGED upstream (issue #17852 cerrado). Slot cerrado.",
}

# open_prs: add #18550, refresh #18528 with the effective gate verdict.
open_prs = s.setdefault("open_prs", [])
by_num = {p.get("number"): p for p in open_prs}
for p in open_prs:
    if p.get("number") == 18528:
        p["state"] = "open_draft"
        p["draft"] = True
        p["head"] = "3ffec8ca5c343b75a3d5b54fcba6d01487ae36ea"
        p["gate"] = "VERDE-SCOPE (efectivo) NEW_FAILURES=0 PREEXISTING=3; el CRUDO sale ROJO por los 3 preexistentes de origin/main"
        p["ci"] = "12 checks pass, 2 pending (Native Linux tests y Format and repository checks), 0 fail"
        p["nota_2026_11_17_1612"] = "Verificado desde GitHub: OPEN, draft=true, MERGEABLE/CLEAN, body con 'Fixes #18260' y 'Changes a default: no'."
if 18550 not in by_num:
    open_prs.append({
        "number": 18550,
        "issue": 18075,
        "state": "open_draft",
        "draft": True,
        "head": "dec975047e0e5a4ca0b063b069fb50919cb37744",
        "title": "Sketch: a fillet or a chamfer reaches the corner symmetric to the one it cuts (#18075)",
        "branch": "spike/issue-18075",
        "body_ok": "Fixes #18075 + 'Changes a default: no' (pr-defaults-line.sh: checked 1 missing 0; publish-pr.sh lo confirmo al abrir)",
        "ci": "6 checks pass, 0 fail, 0 pending al abrir",
        "local": "RED y GREEN medidos en el area (3 tests de sketch_modify): sin el fix 3 failed (EXIT=100), con el fix 3 passed (EXIT=0). Gate reencolado.",
        "nota": "Publicado por el orquestador con bin/publish-pr.sh; el trabajo lo dejo la wave wave-20261116-2107-impl, que murio sin PR.",
    })

# history
hist = s.setdefault("history", [])
hist.append({
    "at": NOW,
    "tipo": "wave",
    "accion": "wave_2026_11_17_1612",
    "detalle": (
        "Calibracion: implement_slots=3, slots_taken=0 (los 3 locks de la wave wave-20261116-2107 "
        "estaban stale: 16058 de 663 min, 18075 de 964 min, 18260 de 784 min -> reapeados CON EVIDENCIA "
        "de que sus duenos (waves muertas) no tenian agente vivo), free_slots=3. comment_watch: SIN "
        "DELTA (las 2 tareas pendientes ya estaban atendidas). "
        "(a) RESCATE: el slot 18075 tenia el fix y el test RED commiteados por la wave muerta "
        "(c026d5aae, 2 archivos, +223) pero SIN PR y con el gate interrumpido (143): rebase lineal sobre "
        "origin/main (-> dec975047), push al fork con --force-with-lease y PR #18550 en DRAFT por "
        "bin/publish-pr.sh (body con 'Fixes #18075' y 'Changes a default: no', pr-defaults-line.sh "
        "checked 1 missing 0; claim-verify rc=0; dup-scan sin duplicado). "
        "(b) VERIFICACION: PR #18528 (issue 18260) tiene veredicto EFECTIVO VERDE-SCOPE "
        "(NEW_FAILURES=0, PREEXISTING=3): los 3 fallos crudos estan en tests/KNOWN_FAILING_TESTS de "
        "origin/main, la baseline local del loop (39 lineas) esta mas vieja que la del upstream (13). "
        "(c) DESPACHOS NUEVOS: 18364 (arco tangente que salta del angulo interior al exterior al "
        "dimensionar la arista, opencode/deepseek-v4.1-flash-free) y 18445 (el icono de Concentricity "
        "en la barra es mas grande que los demas, opencode/glm-5.3-flash-free), ambos por el corredor "
        "del loop con CARGO_TARGET_DIR propio, claim-verify rc=0 y lock tomado. "
        "(d) CERRADOS: #18192 (cerrado por nosotros: el fix era un no-op y el bug ya esta en main por "
        "#17921), #18035 (cerrado por el mantenedor, cubierto por #18014/#18148), #18189 MERGED. "
        "DISCO: 41 GB libres (92% usado); el arbol de targets del orquestador esta en 89 GB (tope 60) "
        "y gc-disk no lo puede bajar porque los 4 targets grandes estan en uso (lock o cargo vivo). "
        "PRs nuestros abiertos: 8 (1 en draft)."
    ),
})

s["updated_at"] = NOW

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(P))
with os.fdopen(fd, "w") as f:
    json.dump(s, f, ensure_ascii=False, indent=2)
os.replace(tmp, P)
print("state.json updated at", NOW)
