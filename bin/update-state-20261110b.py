#!/usr/bin/env python3
"""Second pass of the 2026-11-10 01:54 wave: the #14337 relaunch, the #14256
dispatch, the disk emergency and the two unanswered maintainer requests."""
import json
import os
import tempfile

ORCH_DIR = os.environ.get("ORCH_DIR", "/home/user/.local/share/solidcraft-orch")
WORKTREES_DIR = os.environ.get("WORKTREES_DIR", "/home/user/solidcraft-wt")
SOLIDCRAFT_REPO = os.environ.get("SOLIDCRAFT_REPO", "/home/user/solidcraft")

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


NOW = "2026-11-10T08:25:00Z"
WAVE = "wave-20261110-0154"

# ---------------------------------------------------------------- slots
slots_doc = load("slots.json")
slots = slots_doc["slots"]

slots["14337"] = {
    "issue": 14337,
    "status": "running",
    "pr": None,
    "lock_owner": WAVE,
    "branch": "spike/issue-14337",
    "worktree": os.path.join(WORKTREES_DIR, 'issue-14337'),
    "target_dir": os.path.join(ORCH_DIR, "targets", 'slot-14337'),
    "delegation": (
        "loop: agent-issue.sh (opencode, MiniMax M3.1 Flash), timeout 40 min, "
        "CARGO_TARGET_DIR=targets/slot-14337. PRIMER intento (timeout 30) murio por "
        "ECONNRESET del proveedor SIN dejar commit; segundo intento relanzado 08:12Z."
    ),
    "log": os.path.join(ORCH_DIR, "logs", '14337-wave2.log'),
    "log_primer_intento": "${ORCH_DIR}/logs/14337-wave.log",
    "agent_finished": False,
    "result": (
        "en marcha (2do intento, relanzado 08:12Z con timeout 40 min). "
        "El primer intento (timeout 30) lo mato el proveedor: 'Error: Transport: ECONNRESET: "
        "The socket connection was closed unexpectedly' DESPUES de 26 min de trabajo real "
        "(el agente estaba midiendo la matematica de la rotacion en space_mouse_model.rs), "
        "y NO dejo ningun commit ni diff (worktree limpio, logs/wip-issue-14337.diff = 0 lineas). "
        "El lock NO se solto entre intentos. claim-verify rc=0: el issue sigue libre. "
        "El bug: el HUD digital del 3D mouse se inclina al reves (el dibujo no aplica las "
        "per-axis Invert). La causa raiz ya la trazó el mantenedor en el issue: fn corner en "
        "crates/ui-egui/src/space_mouse_model.rs no aplica el Invert por eje; el test de "
        "referencia tilts_and_twists_turn_the_cap_the_right_way esta en space_mouse_model_tests.rs."
    ),
    "at": NOW,
}

slots["14256"] = {
    "issue": 14256,
    "status": "running",
    "pr": None,
    "lock_owner": WAVE,
    "branch": "spike/issue-14256",
    "worktree": os.path.join(WORKTREES_DIR, 'issue-14256'),
    "target_dir": os.path.join(ORCH_DIR, "targets", 'slot-14256'),
    "delegation": (
        "loop: agent-issue.sh (opencode, MiniMax M3.1 Flash), timeout 40 min, "
        "CARGO_TARGET_DIR=targets/slot-14256"
    ),
    "log": os.path.join(ORCH_DIR, "logs", '14256-wave.log'),
    "agent_finished": False,
    "result": (
        "en marcha (despachado 08:18Z). claim-verify rc=0: el issue esta libre. "
        "Es un bug de UI de sketch: 'Extrude won't let me select the sketch profile' / "
        "'Not able to extrude a fully defined sketch' en el diseno ALIGNMENT TOOL ENDPLATES "
        "(1 feature, 0 bodies), en 0.40.0-rc.3 sobre macOS. El reportador adjunto el diseño "
        "(ALIGNMENT.TOOL.ENDPLATES.sc.zip) en un comentario del issue."
    ),
    "at": NOW,
}

slots_doc["slots"] = slots
save("slots.json", slots_doc)

# ---------------------------------------------------------------- housekeeping
slots_doc = load("slots.json")
slots_doc["housekeeping"] = slots_doc.get("housekeeping", {})
slots_doc["housekeeping"]["2026_11_10"] = {
    "at": NOW,
    "emergencia_de_disco": (
        "El disco llego a 100% (4.3 GB libres) a las 07:11Z: el gate de 12418 mas el probe "
        "diagnostico mas el build web de 2130 se comieron 18 GB. Se corto el probe por PID "
        "exacto (sin pkill) y se reclamaron caches MUERTAS: "
        "solidcraft-wt/issue-12418-fix/target (15G), targets/slot-5857 (37G), targets/slot-2216 "
        "(3.7G), target-wasm2130 (8.2G). Ninguno con cargo vivo, lock o trabajo sin commitear, y "
        "sus PRs (#12574, #11359, #12263) estan publicados y verdes: son caches, no evidencia. "
        "Resultado: 68 GB libres (86% usado)."
    ),
    "lo_que_no_se_toco": (
        "targets/slot-2130 NO se borro (6.5G): es el binario que la sesion interactiva usa para "
        "la grabacion que pidio el mantenedor en #11886. Y ${SOLIDCRAFT_REPO}/target-wt11886 "
        "(77G) se dejo: el worktree wt-11886 sigue en uso para esa misma captura."
    ),
    "locks": (
        "Reapeados por edad con su dueno muerto (wave-20261109-1506, ~650 min): 13151, 14050, "
        "5857 y 12418. Tomados por esta wave: 12124 (ya liberado), 14337 y 14256. "
        "El lock de 9843 (PR abierto y verde) se deja: su wave sigue viva."
    ),
}
save("slots.json", slots_doc)

# ---------------------------------------------------------------- prs
prs_doc = load("prs.json")
for pr in prs_doc["open_prs"]:
    if pr.get("number") == 12574:
        pr["estado_2026_11_10"]["veredicto_del_gate_local"] = (
            "El gate local dio ROJO-SCOPE (2 fallos) y NO es efectivo: el CI de upstream corrio la "
            "suite COMPLETA en el MISMO sha 478dc32362 y fue VERDE (gh run list: CI 478dc32362 "
            "success, PR checks 478dc32362 success). Uno de los dos fallos locales es un TIMEOUT "
            "de nextest (render_workspace::progressive_image_controls_route_to_the_registered_host, "
            "SLOW >120s) y el otro una asercion de ui_kit::settings_search::"
            "collapsed_shortcut_results_enter_reveals_the_command_despite_an_old_page_filter, que "
            "vive en crates/ui-egui/src/prefs.rs (el PR solo AGREGA una fila de preferencia; no "
            "toca la logica del buscador). La maquina estaba saturada durante ese gate."
        )
        pr["estado_2026_11_10"]["lo_que_falta"] = (
            "La captura antes/despues que pidio el mantenedor ('fix that one case on its own and "
            "show it with a screenshot'). Hay un script listo: "
            "${WORKTREES_DIR}/../pr-body-work/capture-12418-evidence.py."
        )
save("prs.json", prs_doc)

# ---------------------------------------------------------------- history
entries = [
    {
        "at": NOW,
        "wave": WAVE,
        "action": "disk_emergency_100pct",
        "detail": (
            "El disco llego a 100% (4.3 GB libres). Se corto el probe diagnostico por PID exacto "
            "(el que se estaba comiendo el espacio; su respuesta ya la daba el CI de upstream) y se "
            "reclamaron 64 GB de caches muertas: issue-12418-fix/target (15G), slot-5857 (37G), "
            "slot-2216 (3.7G), target-wasm2130 (8.2G). Sin cargo vivo, sin lock, sin trabajo sin "
            "commitear; sus PRs estan publicados y verdes. 68 GB libres (86%). "
            "NO se toco slot-2130 (el binario de la grabacion de #11886) ni target-wt11886 "
            "(el worktree de esa captura, 77G)."
        ),
    },
    {
        "at": NOW,
        "wave": WAVE,
        "action": "relaunch_14337",
        "detail": (
            "El corredor de #14337 lo mato el proveedor con 'Transport: ECONNRESET' a los 26 min, "
            "despues de trabajar de verdad (midiendo la rotacion en space_mouse_model.rs) y SIN "
            "dejar commit ni diff (worktree limpio). Se relanzo con timeout 40 min y el mismo "
            "CARGO_TARGET_DIR (targets/slot-14337), sin soltar el lock. Es la clase TRANSPORT ya "
            "conocida: MiniMax es el unico provider autenticado en esta maquina, asi que no hay "
            "modelo alternativo. El RED no se pierde: el worktree se recrea desde el main actual."
        ),
    },
    {
        "at": NOW,
        "wave": WAVE,
        "action": "dispatch_14256",
        "detail": (
            "Slot NUEVO #14256 ('Not able to extrude a fully defined sketch', area:sketch) "
            "despachado con el corredor del loop (timeout 40 min, "
            "CARGO_TARGET_DIR=targets/slot-14256). claim-verify rc=0: el issue esta libre y nadie "
            "lo reclama. El reportador adjunto el diseño (ALIGNMENT.TOOL.ENDPLATES.sc.zip) en un "
            "comentario, que el corredor no lee: si el agente no puede reproducir, no publica."
        ),
    },
    {
        "at": NOW,
        "wave": WAVE,
        "action": "state_consistency",
        "detail": (
            "state.json regenerado desde state/ con merge-state.sh --split y verificado con "
            "merge-state.sh --check: IDENTICO byte a byte (rc=0, 119 claves de primer nivel). "
            "Las entradas de history.jsonl de esta wave: repair_12212_conflict, reap_dead_locks, "
            "dispatch_14337, verify_all_open_prs, disk_gc, disk_emergency_100pct, "
            "relaunch_14337, dispatch_14256, state_consistency."
        ),
    },
]
with open(os.path.join(ORCH, "history.jsonl"), "a", encoding="utf-8") as fh:
    for e in entries:
        fh.write(json.dumps(e, ensure_ascii=False) + "\n")

print("state split files updated (pass 2)")
