#!/usr/bin/env python3
"""Update the orchestrator state for the 2026-11-08 22:18 wave.

The truth lives in state/<concepto>.json; state.json is an artefact rebuilt
by merge-state.sh. This script edits the split files atomically.
"""
import json
import os
import tempfile

ORCH_DIR = os.environ.get("ORCH_DIR", "/home/user/.local/share/solidcraft-orch")
WORKTREES_DIR = os.environ.get("WORKTREES_DIR", "/home/user/solidcraft-wt")

ORCH = ORCH_DIR
STATE = os.path.join(ORCH, "state")


def load(name):
    with open(os.path.join(STATE, name), encoding="utf-8") as fh:
        return json.load(fh)


def save(name, data):
    path = os.path.join(STATE, name)
    fd, tmp = tempfile.mkstemp(dir=STATE, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False, indent=2, sort_keys=False)
        fh.write("\n")
    os.replace(tmp, path)


NOW = "2026-11-09T01:35:00Z"

# ---------------------------------------------------------------- slots
slots_doc = load("slots.json")
slots = slots_doc["slots"]

for issue in (13424, 13527, 13471):
    slots[str(issue)] = {
        "issue": issue,
        "status": "running",
        "lock_owner": "wave-20261108-2218",
        "delegation": "loop: agent-issue.sh (opencode, MiniMax-M3.1-Flash), timeout 45 min",
        "branch": "wip",
        "worktree": os.path.join(WORKTREES_DIR, f"issue-{issue}"),
        "target_dir": os.path.join(ORCH_DIR, "targets", f"slot-{issue}"),
        "log": os.path.join(ORCH_DIR, "logs", f"{issue}-wave.log"),
        "agent_log": os.path.join(WORKTREES_DIR, f"issue-{issue}.log"),
        "agent_finished": False,
        "result": "en marcha: el corredor del loop (agent-issue.sh) esta con el modelo. El freno del reclamo dio VERDICT=OK (el issue esta libre) y el worktree se preparo desde refs/remotes/agent/upstream-main.",
        "at": NOW,
    }

slots_doc["slots"] = slots
save("slots.json", slots_doc)

# ---------------------------------------------------------------- prs
prs_doc = load("prs.json")
for pr in prs_doc["open_prs"]:
    num = pr.get("number")
    if num == 12574:
        pr["estado_2026_11_08"] = {
            "head": "77d0ea037",
            "ci": "success (8 pass / 16 skipping / 0 fail)",
            "approved_for_ci": False,
            "merge_state": "CLEAN",
            "ping": "EN-TURNO",
            "verificado_2026_11_08_2218": "leido de GitHub: draft=false, MERGEABLE/CLEAN, head 77d0ea037 == rama del fork; body con 'Fixes #12418' y 'Changes a default: yes - ...'",
        }
    elif num == 12263:
        pr["estado_2026_11_08"] = {
            "head": "fd190eafc",
            "ci": "success (30 pass / 18 skipping / 0 fail)",
            "approved_for_ci": False,
            "merge_state": "CLEAN",
            "ping": "EN-TURNO",
            "verificado_2026_11_08_2218": "leido de GitHub: draft=false, MERGEABLE/CLEAN, head fd190eafc == rama del fork; body con 'Fixes #2216' y 'Changes a default: no'",
        }
    elif num == 12212:
        pr["estado_2026_11_08"] = {
            "head": "046eb2915",
            "ci": "success (31 pass / 16 skipping / 0 fail)",
            "approved_for_ci": False,
            "merge_state": "CLEAN",
            "ping": "EN-TURNO",
            "verificado_2026_11_08_2218": "leido de GitHub: draft=false, MERGEABLE/CLEAN, head 046eb2915 == rama del fork; body con 'Fixes #12124' y 'Changes a default: no'",
        }
    elif num == 11886:
        pr["estado_2026_11_08"] = {
            "head": "4c32a418f",
            "ci": "success (13 pass / 14 skipping / 0 fail)",
            "approved_for_ci": True,
            "merge_state": "UNKNOWN (GitHub recalcula; la API dio mergeable_state=unknown)",
            "ping": "LISTO",
            "verificado_2026_11_08_2218": "leido de GitHub: draft=false, head 4c32a418f == rama del fork; body con 'Refs #2130' y 'Changes a default: yes - ...'",
        }
    elif num == 11359:
        pr["estado_2026_11_08"] = {
            "head": "1c1a82a53",
            "ci": "success (13 pass / 16 skipping / 0 fail) - el ROJO de formato pending que se anotaba el 08 ya NO esta",
            "approved_for_ci": True,
            "merge_state": "CLEAN (mergeable_state=clean en la API)",
            "ping": "LISTO",
            "verificado_2026_11_08_2218": "leido de GitHub: draft=false, head 1c1a82a53 == rama del fork; body con 'Fixes #5857' y 'Changes a default: yes - ...'",
        }
    elif num == 9843:
        pr["estado_2026_11_08"] = {
            "head": "7db791f00",
            "ci": "success (12 pass / 17 skipping / 0 fail)",
            "approved_for_ci": False,
            "merge_state": "CLEAN (mergeable_state=clean en la API)",
            "ping": "LISTO",
            "verificado_2026_11_08_2218": "leido de GitHub: draft=false, head 7db791f00 == rama del fork; body con 'Fixes #7114' y 'Changes a default: yes - ...'",
        }

save("prs.json", prs_doc)

# ---------------------------------------------------------------- notes
notes = load("notes.json")
notes["wave_2026_11_08_2218"] = {
    "at": NOW,
    "calibracion": {
        "implement_slots": 5,
        "slots_taken": 0,
        "free_slots": 5,
        "cores": 16,
        "mem_avail": "58 G",
        "gate_may_start": 1,
        "heavy_lock": 0,
    },
    "candidatos_de_la_wave": {
        "de_claim_guard": 24,
        "elegidos": [13424, 13527, 13471],
        "descartados": {
            "13424": "elegido: repor de bug de sketch con pasos de reproduccion claros (copia de boceto + plano de offset), area:sketch, no kernel",
            "13527": "elegido: flecha de dimension incorrecta tras un chaflan de un agujero (area:doc, geometria exacta en el body del issue)",
            "13471": "elegido: el boceto pierde los vinculos a la geometria proyectada al cerrar el sketcher (area:sketch, hay mensaje de error exacto)",
            "13545_y_13478": "descartados: el triage del mantenedor (dudedagger42) los agrupa bajo el #4325, que sigue ABIERTO upstream y ya agrupa los informes de ese rechazo",
            "13483": "descartado: el triage lo manda a #7570 (boolean del kernel, area pausada)",
            "13496": "descartado: chaflanes que se pisan entre si, es geometria de kernel/modelado",
            "13503": "descartado: area:render (la columna vertebral de Nate, no se toca)",
            "13907_13466_13461": "descartados: son la clase de crash 'ended without a clean exit' que YA arreglo el PR #12891 (mergeado por el mantenedor el 2026-11-08T04:09Z). No hay bug nuevo que arreglar",
            "13516_13509_13506_13458_13436_13430_13451_13544_13926": "descartados: sin pasos de reproduccion o dependen del hardware del reporte (GPU, macOS, Windows-only)",
        },
    },
    "corredores_despachados": [
        {
            "issue": 13424,
            "lock": "wave-20261108-2218",
            "runner": "agent-issue.sh (opencode MiniMax-M3.1-Flash), timeout 45 min",
            "worktree": "/home/user/solidcraft-wt/issue-13471 -> issue-13424",
            "target": "targets/slot-13424",
            "claim": "VERDICT=OK (issue libre)",
        },
        {
            "issue": 13527,
            "lock": "wave-20261108-2218",
            "runner": "agent-issue.sh (opencode MiniMax-M3.1-Flash), timeout 45 min",
            "target": "targets/slot-13527",
            "claim": "VERDICT=OK (issue libre)",
        },
        {
            "issue": 13471,
            "lock": "wave-20261108-2218",
            "runner": "agent-issue.sh (opencode MiniMax-M3.1-Flash), timeout 45 min",
            "target": "targets/slot-13471",
            "claim": "VERDICT=OK (issue libre)",
        },
    ],
    "disco": {
        "antes": "61 GB libres (88% usado)",
        "accion": "gc-disk.sh --stale-targets (el arbol de targets del orquestador estaba en 215 GB contra un tope de 60 GB)",
        "despues": "155 GB libres (68% usado)",
        "borrados": ["targets/slot-12418 (21.2 GB)", "targets/slot-2130 (21.2 GB)", "targets/slot-5857 (52.0 GB)"],
        "conservados": ["targets/slot-2216 (caliente, 0 h)", "targets/slot-9843 (caliente, 2 h)"],
    },
    "verificacion_de_prs": {
        "metodo": "leido de GitHub con gh pr view / gh pr checks; el head del PR se comparo con ls-remote del fork",
        "resultado": "los 6 PRs abiertos: draft=false, todos los checks en pass o skipping, 0 fallos, y el headRefOid == la rama del fork",
        "detalle": {
            "12574": "8 pass / 16 skipping",
            "12263": "30 pass / 18 skipping",
            "12212": "31 pass / 16 skipping",
            "11886": "13 pass / 14 skipping",
            "11359": "13 pass / 16 skipping (el ROJO de formato pending anotado el 08 ya no esta)",
            "9843": "12 pass / 17 skipping",
        },
        "cuerpo": "los 6 cuerpos tienen la linea 'Changes a default:' y el 'Fixes #N' o 'Refs #N'",
    },
    "nota_de_proceso": "opencode NO esta en el PATH de la sesion (vive en ~/.opencode/bin); el corredor se lo agrega solo, asi que el runner arranca bien. Los tres worktrees se prepararon desde refs/remotes/agent/upstream-main, cada uno con su CARGO_TARGET_DIR (targets/slot-<issue>), y los tres compilan en paralelo sin pelear por el lock de cargo.",
}
save("notes.json", notes)

print("state/ actualizado")
