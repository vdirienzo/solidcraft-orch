# Brief: hacer el orquestador portable a otra PC

POR QUE: el repo `vdirienzo/solidcraft-orch` (privado) ya tiene el codigo, pero los scripts tienen
rutas ABSOLUTAS (`/home/user/.local/share/solidcraft-orch`, `/home/user/solidcraft`,
`/home/user/solidcraft-wt`, `/home/user/.local/share/solidcraft-loop`, `/home/user/.hermes/scripts`).
En otra PC, con otro usuario, no corren. El usuario quiere usarlas EN PARALELO en otra maquina:
para eso las rutas tienen que venir de variables de entorno con default.

## LO QUE TENES QUE HACER

### 1) Parametrizar las rutas

En cada script de `bin/` que tenga rutas hardcodeadas, defini (al principio del script) las
variables con default, para que sigan funcionando aqui sin cambiar nada:

```bash
ORCH_DIR="${ORCH_DIR:-/home/user/.local/share/solidcraft-orch}"
LOOP_DIR="${LOOP_DIR:-/home/user/.local/share/solidcraft-loop}"
SOLIDCRAFT_REPO="${SOLIDCRAFT_REPO:-/home/user/solidcraft}"
WORKTREES_DIR="${WORKTREES_DIR:-/home/user/solidcraft-wt}"
HERMES_SCRIPTS="${HERMES_SCRIPTS:-/home/user/.hermes/scripts}"
```

Y reemplaza cada uso de la ruta literal por la variable. Ojo:
- hay scripts que YA usan `ORCH_DIR="${ORCH_DIR:-...}"` (gate-queue.sh): no los rompas, solo
  completalos con las variables que les falten.
- las rutas de `target/` de los slots: `targets/` tiene que ser SIEMPRE relativo al `ORCH_DIR`
  (que es como ya funciona `slot-target-dir.sh`).
- los worktrees: `$WORKTREES_DIR/issue-$N`.
- NO dejes rutas hardcodeadas de `/home/user` fuera de los defaults.

Criterio de aceptación: `grep -rn '/home/user' bin/ | grep -v ':-/home/user'` no devuelve nada
(solo pueden quedar rutas dentro de los defaults, que es lo correcto).

### 2) Copiar el conocimiento al repo

La skill del orquestador vive en
`/home/user/.hermes/skills/productivity/solidcraft-multi-agent-orchestrator/` y sus `references/`
tienen las reglas, las lecciones y los traps (que en otra PC no van a estar). Copia los
`references/` a `docs/` del repo (con `cp -r`, sin modificarlos) y anade en el README una seccion
que apunte a `docs/` como "las reglas, los traps y las lecciones".

### 3) Verificar

- Corré las 6 suites: tienen que dar rc=0:
  bash bin/test-gate-quick.sh ; bash bin/test-gate-claim.sh ; bash bin/test-verify-pr.sh ;
  bash bin/test-gate-baseline.sh ; bash bin/test-slot-parallelism.sh ; python3 bin/test-rules.py
- Corré el pipeline en modo real pero que NO toque GitHub: `python3 bin/pipeline.py` (es
  idempotente: si no hay drafts, no hace nada). Que no tire error.
- `bash bin/build-slot.sh --status` y `bash bin/gate-queue.sh --list`: que no tiren error.
- Un test nuevo `bin/test-portability.sh` que verifique que NINGUN script de bin/ (salvo los
  defaults documentados) tiene rutas absolutas de /home/user, y que los scripts que usan
  ORCH_DIR/LOOP_DIR/SOLIDCRAFT_REPO/WORKTREES_DIR tienen las cuatro variables definidas.
- NO compiles Rust.

### 4) Commit y push

```
cd /home/user/.local/share/solidcraft-orch
git add -A
git commit -m "Orquestador portable: las rutas salen de variables con default, para correrlo en otra PC"
git push origin main
```

## LO QUE NO TOCAS (hay otros agentes escribiendo en esos archivos ahora mismo)

- NO toques: `bin/claim-verify.sh`, `bin/claim-race.sh`, `bin/test-claim-verify.sh`,
  `bin/test-gate-claim.sh`, `state.json`, el directorio `state/`, `merge-state.sh`,
  `bin/test-state-split.sh`, `workflow.yaml`, `bin/workflow-validate.py`,
  `bin/workflow-runner.sh`, `bin/test-workflow.sh`, `bin/test-workflow-runner.sh`.
  Si un script de esos tiene rutas hardcodeadas, NO lo edites: anotalo en tu informe y listo.
- NO borres los `.bak` (otro agente lo esta haciendo).
- Reemplazo atomico (os.replace / mv) para TODO archivo que edites: los crons corren
  pipeline.py (cada 5 min) y gate-queue.sh (cada 3 min) y no se puede editar un script en vivo.

## LO QUE DEVUELVES
La lista de scripts que parametrizaste, el resultado del grep de aceptacion, la confirmacion de que
docs/ quedo copiado, el rc de las 6 suites y de tu test nuevo, la salida de pipeline.py, y el SHA
del commit. Si algo no lo pudiste hacer, decilo con el error exacto. No inventes resultados.
