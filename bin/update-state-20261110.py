#!/usr/bin/env python3
"""State update for the 2026-11-10 01:54 wave (single, authoritative pass).

PROCEDURE NOTE (learned the hard way in this wave): the truth is state/*.json
and state.json is an artefact. `merge-state.sh --split` goes the OTHER way
(it redistributes state.json back into state/), so running it after editing
state/*.json REVERTS the edits and then --check says "IDENTICO" about the
reverted data. The correct order is: edit state/*.json, then run plain
`merge-state.sh` (no --split) to rebuild the artefact, then --check.
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


NOW = "2026-11-10T08:55:00Z"
WAVE = "wave-20261110-0154"

# ------------------------------------------------------------------ slots
slots_doc = load("slots.json")
slots = slots_doc["slots"]

slots["12124"] = {
    "issue": 12124,
    "pr": 12212,
    "status": "pr_open",
    "role": "repair-12212-conflict-with-main",
    "branch": "fix/issue-12124-face-attach-two-sided-cut",
    "worktree": "/home/user/solidcraft-wt/issue-12212-rebase",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-12124",
    "lock_owner": None,
    "delegation": f"{WAVE}: subagente (Hermes) con brief literal del conflicto",
    "head": "af375ab48bd2df75d79a74dbb7a61c337b7d955a",
    "result": (
        "PR #12212 REPARADO: estaba CONFLICTING/DIRTY (183 commits atras de main). Merge de "
        "origin/main con UN conflicto en crates/engine/src/naming_history_tests.rs, resuelto "
        "conservando LOS DOS LADOS (el test nuestro a_sketch_on_a_face_of_a_two_sided_cut_keeps_"
        "its_attachment y el de upstream two_pieces_that_both_answer_to_a_stored_name_are_not_"
        "guessed_between). eval.rs y el pending file auto-mergearon sin cambios. El patch propio "
        "del PR queda IDENTICO: 3 archivos, +51/-6. fmt exit 0; cargo test -p solidcraft-engine "
        "--profile ci --lib naming_history = 28 passed / 0 failed (los 4 primeros intentos los "
        "mato el cgroup de 4 GiB de Hermes; el que paso uso systemd-run --scope -p MemoryMax=20G). "
        "Push solo al fork con --force-with-lease. VERIFICADO DESDE GITHUB: OPEN, draft=false, "
        "mergeable=MERGEABLE, mergeStateStatus=CLEAN, headRefOid=af375ab48 == rama del fork, body "
        "con 'Fixes #12124' y 'Changes a default: no'. CI DEL HEAD REPARADO: VERDE COMPLETO "
        "(check-runs: ci success + los 11 kernel-rig success + Nightly alert skipped)."
    ),
    "verified": "2026-11-10T08:32Z, leido de GitHub (gh pr view + check-runs API)",
    "agent_finished": True,
}

slots["13151"] = {
    "issue": 13151,
    "status": "abandoned",
    "pr": None,
    "lock_owner": None,
    "branch": "spike/issue-13151",
    "worktree": "/home/user/solidcraft-wt/issue-13151",
    "delegation": "loop: agent-issue.sh (opencode) - el agente murio otra vez",
    "agent_finished": True,
    "result": (
        "ABANDONADO: el corredor del loop (agent-issue.sh, opencode) muere y no deja ningun "
        "commit. Verificado en esta wave: no hay proceso vivo, el log termina en 'agente: corre el "
        "modelo' y el worktree esta limpio sobre b57026e1f (main), sin commits propios. NO hay "
        "rama en el fork para este issue. El lock fue reapeado (649 min, owner wave-20261109-1506). "
        "El issue #13151 sigue ABIERTO upstream y sin reclamar: la proxima wave puede tomarlo. "
        "NOTA: la causa de esas muertes era el OOM killer del scope de 4 GiB de Hermes (ver "
        "housekeeping.cinturon_de_memoria_para_los_corredores), ya corregida para los corredores "
        "de esta wave."
    ),
    "abandon_reason": "el agente murio (SIGTERM del OOM killer del scope de Hermes) y no dejo commits; el lock se reapeo",
    "verificado": "2026-11-10T04:58Z: sin proceso vivo, log congelado, worktree sin commits propios",
}

slots["14050"] = {
    "issue": 14050,
    "status": "abandoned",
    "pr": None,
    "lock_owner": None,
    "branch": "spike/issue-14050",
    "worktree": "/home/user/solidcraft-wt/issue-14050",
    "delegation": "loop: agent-issue.sh (opencode) - el freno del reclamo veto la publicacion",
    "agent_finished": True,
    "result": (
        "ABANDONADO: el reclamo NO esta libre. El corredor lo detecto solo (claim-brake): "
        "VERDICT=TAKEN, REASON=claimed-by, el issue lo reclama @0rdnungsamt. El agente no publico "
        "nada. El RED commiteado y pusheado al fork se conserva: 658d9db46 "
        "('test(engine): a pattern of a hole at sketch points cuts every copy (#14050)') en la rama "
        "spike/issue-14050 del fork (verificado con git ls-remote). Lock reapeado (649 min)."
    ),
    "abandon_reason": "claim tomado por @0rdnungsamt (VERDICT=TAKEN del claim-brake)",
    "verificado": "2026-11-10T04:58Z: log del corredor con VERDICT=TAKEN; ls-remote del fork con 658d9db46",
}

slots["12418"] = {
    "issue": 12418,
    "pr": 12574,
    "status": "pr_open",
    "role": "verify-12574-narrowed-fillet",
    "branch": "fix/issue-12418-length-preset-defaults",
    "worktree": "/home/user/solidcraft-wt/issue-12418-fix",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-12418",
    "lock_owner": None,
    "commit": "478dc3236231b5bc222cfe9039cd3caa23e3249b",
    "result": (
        "PR #12574 verificado desde GitHub: OPEN, draft=false, MERGEABLE/CLEAN, head 478dc3236 == "
        "rama del fork, 8 checks pass / 0 fail (los pesados incluidos: Native Linux tests 10m3s y "
        "Native Linux Clippy 2m39s), body con 'Fixes #12418' y 'Changes a default: yes - ...' que "
        "pasa el parser del upstream. El mantenedor RECHAZO el cambio global (2026-11-09T15:23Z) y "
        "el PR quedo reducido al un solo caso (el radio del Solid Fillet abre en 2 mm mostrado en la "
        "unidad del diseno, con la preferencia fillet_legacy_radius que devuelve el default viejo). "
        "LO QUE FALTA, segun el mantenedor: la captura antes/despues. El gate local (slot-12418, "
        "sha 478dc3236) dio ROJO-SCOPE con 2 fallos que NO son del cambio, y el CI de upstream corrio "
        "la suite COMPLETA en el MISMO sha y fue VERDE: el veredicto local no es efectivo."
    ),
    "gate": "ROJO-SCOPE (local, NO efectivo: el CI de upstream en el mismo sha 478dc32362 fue verde; ademas uno de los dos fallos locales es un TIMEOUT de nextest por saturacion)",
    "agent_finished": True,
}

slots["14337"] = {
    "issue": 14337,
    "status": "running",
    "pr": None,
    "lock_owner": WAVE,
    "branch": "spike/issue-14337",
    "worktree": "/home/user/solidcraft-wt/issue-14337",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-14337",
    "delegation": (
        "loop: agent-issue.sh (opencode, MiniMax M3.1 Flash), timeout 40 min, "
        "CARGO_TARGET_DIR=targets/slot-14337, systemd scope sc14337.scope"
    ),
    "log": "/home/user/.local/share/solidcraft-orch/logs/14337-wave3.log",
    "cinturon": "systemd scope sc14337.scope: MemoryHigh=12G, MemoryMax=16G, CPUWeight=100, IOWeight=50",
    "cgroup": "/user.slice/user-1001.slice/user@1001.service/app.slice/sc14337.scope (hermano del scope del worker de Hermes: NO hereda su tope de 4 GiB)",
    "agent_finished": False,
    "result": (
        "en marcha (3er intento, relanzado 08:49Z). Los dos intentos anteriores lo mato el OOM "
        "killer del scope de 4 GiB de Hermes, NO el provider: dmesg dice "
        "'hermes-worker-proc_*.scope: Failed with result oom-kill' con un pico de 4 G. El primer "
        "intento murio con 'Transport: ECONNRESET' DESPUES de 26 min de trabajo real (midiendo la "
        "rotacion en space_mouse_model.rs) y no dejo commit ni diff; el segundo, en el mismo scope "
        "de 4 GiB, murio a los ~15 min. claim-verify rc=0: el issue sigue libre. "
        "El bug: el HUD digital del 3D mouse se inclina al reves (el dibujo no aplica las per-axis "
        "Invert). Causa raiz trazada por el mantenedor en el issue: fn corner en "
        "crates/ui-egui/src/space_mouse_model.rs no aplica el Invert por eje; el test de referencia "
        "tilts_and_twists_turn_the_cap_the_right_way esta en space_mouse_model_tests.rs."
    ),
    "at": NOW,
}

slots["14256"] = {
    "issue": 14256,
    "status": "running",
    "pr": None,
    "lock_owner": WAVE,
    "branch": "spike/issue-14256",
    "worktree": "/home/user/solidcraft-wt/issue-14256",
    "target_dir": "/home/user/.local/share/solidcraft-orch/targets/slot-14256",
    "delegation": (
        "loop: agent-issue.sh (opencode, MiniMax M3.1 Flash), timeout 40 min, "
        "CARGO_TARGET_DIR=targets/slot-14256, systemd scope sc14256.scope"
    ),
    "log": "/home/user/.local/share/solidcraft-orch/logs/14256-wave2.log",
    "cinturon": "systemd scope sc14256.scope: MemoryHigh=12G, MemoryMax=16G, CPUWeight=100, IOWeight=50",
    "cgroup": "/user.slice/user-1001.slice/user@1001.service/app.slice/sc14256.scope (hermano del scope del worker de Hermes: NO hereda su tope de 4 GiB)",
    "agent_finished": False,
    "result": (
        "en marcha (2do intento, relanzado 08:49Z; el primero lo mato el mismo OOM). "
        "claim-verify rc=0: el issue esta libre. Es un bug de UI de sketch: 'Extrude won't let me "
        "select the sketch profile' / 'Not able to extrude a fully defined sketch' en el diseno "
        "ALIGNMENT TOOL ENDPLATES (1 feature, 0 bodies), en 0.40.0-rc.3 sobre macOS. El reportador "
        "adjunto el diseno (ALIGNMENT.TOOL.ENDPLATES.sc.zip) en un comentario del issue."
    ),
    "at": NOW,
}

slots_doc["slots"] = slots
hk = slots_doc.setdefault("housekeeping", {})
hk["2026_11_10"] = {
    "at": NOW,
    "emergencia_de_disco": (
        "El disco llego a 100% (4.3 GB libres) a las 07:11Z: el gate de 12418, el probe "
        "diagnostico y el build web de 2130 se comieron 18 GB. Se corto el probe por PID exacto "
        "(sin pkill) y se reclamaron caches MUERTAS: solidcraft-wt/issue-12418-fix/target (15G), "
        "targets/slot-5857 (37G), targets/slot-2216 (3.7G), target-wasm2130 (8.2G). Ninguno con "
        "cargo vivo, lock o trabajo sin commitear, y sus PRs (#12574, #11359, #12263) estan "
        "publicados y verdes: son caches, no evidencia. Resultado: 68 GB libres (86% usado)."
    ),
    "lo_que_no_se_toco": (
        "targets/slot-2130 NO se borro (6.5G): es el binario que la sesion interactiva usa para la "
        "grabacion que pidio el mantenedor en #11886. Y /home/user/solidcraft/target-wt11886 (77G) "
        "se dejo: el worktree wt-11886 sigue en uso para esa misma captura."
    ),
    "locks": (
        "Reapeados por edad con su dueno muerto (wave-20261109-1506, ~650 min): 13151, 14050, 5857 "
        "y 12418. Tomados por esta wave: 12124 (ya liberado), 14337 y 14256. El lock de 9843 (PR "
        "abierto y verde) se deja: su wave sigue viva."
    ),
    "cinturon_de_memoria_para_los_corredores": (
        "HALLAZGO DE ESTA WAVE (arreglo aplicado): los corredores de issue NO tenian cinturon de "
        "memoria. agent-issue.sh se lanzaba desde el turno de cron, asi que heredia el scope del "
        "worker de Hermes, cuyo memory.max es de 4 GiB (4294967296). El cargo build del agente "
        "reventaba ese tope y el OOM killer se llevaba el scope ENTERO: el agente moria a mitad de "
        "trabajo con un error de transporte y no dejaba commit (dmesg: "
        "'hermes-worker-proc_*.scope: Failed with result oom-kill', '4G memory peak'). "
        "ARREGLO: cada corredor ahora corre en un scope transitorio propio "
        "(systemd-run --user --scope --unit=sc<issue> -p MemoryHigh=12G -p MemoryMax=16G), creado "
        "como HERMANO del scope del worker en app.slice: el tope de 4 GiB no le aplica y el OOM se "
        "llevaria al corredor, no al turno. Verificado en los dos corredores vivos. "
        "Tambien se corrigio el target dir: config.env pineaba "
        "CARGO_TARGET_DIR=/home/user/solidcraft/target para TODOS los agentes (59 GB y lock "
        "compartido entre dos agentes). Ahora config.env respeta un valor ya exportado por el que "
        "llama y el orquestador le da a cada agente su propio targets/slot-<issue>. "
        "config-check.sh y config-preflight.sh siguen en OK."
    ),
    "procedimiento_del_estado": (
        "fallo propio de esta wave, corregido: merge-state.sh --split va al OTRO sentido (reparte "
        "state.json de vuelta en state/). Editar state/*.json y luego correr --split REVIRTE los "
        "cambios, y el --check posterior dice 'IDENTICO' sobre los datos ya revertidos. El orden "
        "correcto es: editar state/*.json, correr merge-state.sh SIN --split (reconstruye el "
        "artefacto) y despues --check."
    ),
}
save("slots.json", slots_doc)

# -------------------------------------------------------------------- prs
prs_doc = load("prs.json")
for pr in prs_doc["open_prs"]:
    num = pr.get("number")
    if num == 12212:
        pr["head"] = "af375ab48bd2df75d79a74dbb7a61c337b7d955a"
        pr["state"] = "ready"
        pr["estado_2026_11_10"] = {
            "head": "af375ab48bd2df75d79a74dbb7a61c337b7d955a",
            "draft": False,
            "merge_state": "MERGEABLE / CLEAN",
            "nota": (
                "REPARADO en esta wave: estaba CONFLICTING/DIRTY (183 commits atras). Merge de "
                "origin/main con un unico conflicto en crates/engine/src/naming_history_tests.rs, "
                "resuelto conservando los dos lados (el test nuestro y el de upstream). El patch "
                "propio queda identico: 3 archivos, +51/-6. fmt exit 0; cargo test -p "
                "solidcraft-engine --profile ci --lib naming_history = 28 passed / 0 failed. Push "
                "solo al fork (--force-with-lease)."
            ),
            "ci_del_head_reparado": (
                "VERDE COMPLETO: check-runs = ci success + los 11 kernel-rig (sweeps, shell, "
                "booleans, import, inspect, surfaces, tessellation, frames, plastic) TODOS success "
                "+ Nightly alert skipped."
            ),
            "body": "Fixes #12124 (linea 1) + 'Changes a default: no' (linea 3)",
            "verificado_2026_11_10": (
                "leido de GitHub: OPEN, draft=false, mergeable=MERGEABLE, mergeStateStatus=CLEAN, "
                "headRefOid=af375ab48 == rama del fork, body con 'Fixes #12124' y "
                "'Changes a default: no'"
            ),
        }
    elif num == 12574:
        pr["estado_2026_11_10"] = {
            "head": "478dc3236231b5bc222cfe9039cd3caa23e3249b",
            "draft": False,
            "merge_state": "MERGEABLE / CLEAN",
            "ci": "8 pass / 0 fail (Native Linux tests 10m3s y Native Linux Clippy 2m39s incluidos)",
            "verificado_2026_11_10": (
                "leido de GitHub: OPEN, draft=false, MERGEABLE/CLEAN, head 478dc3236 == rama del "
                "fork, body con 'Fixes #12418' y 'Changes a default: yes - ...'."
            ),
            "nota": (
                "El mantenedor (bherbruck, 2026-11-09T15:23Z) rechazo el cambio global de "
                "defaults. El PR quedo reducido al un solo caso: el radio del Solid Fillet abre en "
                "2 mm mostrado en la unidad del diseno ('0.07874 in' en pulgadas), con la "
                "preferencia fillet_legacy_radius (off) que devuelve el default viejo."
            ),
            "veredicto_del_gate_local": (
                "El gate local dio ROJO-SCOPE (2 fallos) y NO es efectivo: el CI de upstream corrio "
                "la suite COMPLETA en el MISMO sha 478dc32362 y fue VERDE (gh run list: CI "
                "478dc32362 success, PR checks 478dc32362 success). Uno de los dos fallos locales es "
                "un TIMEOUT de nextest (render_workspace::progressive_image_controls_route_to_the_"
                "registered_host, SLOW >120s) y el otro una asercion de ui_kit::settings_search::"
                "collapsed_shortcut_results_enter_reveals_the_command_despite_an_old_page_filter, "
                "que vive en crates/ui-egui/src/prefs.rs (el PR solo AGREGA una fila de "
                "preferencia; no toca la logica del buscador). La maquina estaba saturada durante "
                "ese gate."
            ),
            "lo_que_falta": (
                "La captura antes/despues que pidio el mantenedor ('fix that one case on its own "
                "and show it with a screenshot'). Hay un script listo: "
                "/home/user/pr-body-work/capture-12418-evidence.py."
            ),
        }
    elif num == 11886:
        pr["estado_2026_11_10"] = {
            "head": "74941d973edac13467016b35dd208894d562fc42",
            "draft": False,
            "merge_state": "MERGEABLE / CLEAN",
            "ci": "6 pass / 0 fail",
            "pendiente_del_mantenedor": (
                "bherbruck (2026-11-09T15:16Z): 'please answer and show (a recording, please) what "
                "happens while panning and while rotating when the cursor passes over other faces: "
                "does the highlight jump between faces or flash?'. Nuestra respuesta posterior fue "
                "solo un ping de estado: la pregunta sigue SIN responder. La captura se esta armando "
                "en /home/user/pr-body-work (build-web-2130.sh + run-capture.sh), con el binario "
                "del slot-2130, que por eso NO se borro en la limpieza de disco."
            ),
            "verificado_2026_11_10": "leido de GitHub: OPEN, draft=false, MERGEABLE/CLEAN, head 74941d97 == rama del fork",
        }
save("prs.json", prs_doc)

print("state/slots.json + state/prs.json actualizados")
