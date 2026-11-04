# Brief A: declarar el grafo del orquestador y su runner

POR QUE: el orquestador tiene 49 scripts y el flujo esta implicito en los scripts y en la cabeza de
quien lo maneja. Hoy nadie puede responder "que sigue" ni "donde se trabo" sin reconstruir el estado
a mano. La solucion NO es un framework (LangGraph): es DECLARAR el grafo que ya existe y que exista
un runner que lo ejecute. Nada de esto puede romper lo que anda hoy.

## LO QUE TENES QUE ENTREGAR

### 1) /home/user/.local/share/solidcraft-orch/workflow.yaml

Un YAML declarativo con los nodos del proceso de un issue. Cada nodo con:
   id, script (el comando que lo ejecuta, o null si lo hace un agente), lee (los artefactos que
   necesita), escribe (los que produce), precondiciones (que tienen que ser verdad para correr),
   si_falla (reintentar / descartar / escalar / esperar), cron (cada cuanto corre, si lo tiene),
   compilacion_pesada (si/no)

Los nodos a declarar son los que YA EXISTEN (no inventes otros):
   buscar-issue, claim-verify, causa-raiz, test-red, fix, draft-pr, pipeline, gate-queue, gate,
   gate-baseline, verify-pr, ci-upstream

Las aristas: un bloque "flujo" con el orden y las condiciones de salto. Por ejemplo: si causa-raiz
termina en "la causa esta en solidcore", el issue se descarta; si test-red no deja un commit, el
nodo reintenta una vez y despues escala; si el gate da verde, draft-pr pasa a ready.

### 2) /home/user/.local/share/solidcraft-orch/bin/workflow-validate.py

Un validador que falle si falta un nodo de los de arriba, si una arista apunta a un nodo inexistente,
o si un nodo declara un script que no esta en bin/. Con --json y exit code 0/1.
Y un test bin/test-workflow.sh que incluya una PRUEBA NEGATIVA: tiene que FALLAR cuando el
validador se apunta a un grafo roto (si el test siempre pasa, el validador no sirve).

### 3) /home/user/.local/share/solidcraft-orch/bin/workflow-runner.sh

Un runner que lea el YAML, determine que nodos son ELEGIBLES ahora segun su estado real en disco
(si hay un PR en draft sin veredicto, gate-queue es elegible; si la cola esta vacia, no), y ejecute
UN nodo elegible. Con --list (solo listar) y --dry-run (imprimir sin hacer).
NO ejecutes los nodos que compilan Rust (gate, gate-queue): esos los maneja el cron que ya existe
(solidcraft-gate-queue). El runner es para lo que no tiene cron.
Test bin/test-workflow-runner.sh: con el estado vacio no propone nada; con un PR en draft sin
veredicto propone gate-queue; con la cola con un item propone el drain.

## REGLAS
- Los scripts que ya existen NO se tocan: pipeline.py, gate-queue.sh, gate-runner.sh, gate.sh,
  slot-lock.sh, claim-verify.sh, claim-race.sh, verify-pr.sh. Son tuyos SOLO los archivos NUEVOS:
  workflow.yaml, bin/workflow-validate.py, bin/workflow-runner.sh, bin/test-workflow.sh,
  bin/test-workflow-runner.sh.
- Si un script existente no te sirve como esta, NO lo cambies: describi en el YAML como se llama.
- Reemplazo atomico (os.replace o mv). NUNCA edites in-place un archivo que se este ejecutando.
- NO compiles Rust: la caja esta ocupada con los gates. Este trabajo es de bash y python.
- Al final corré las suites existentes y todas tienen que dar rc=0:
  bash bin/test-gate-quick.sh ; bash bin/test-gate-claim.sh ; bash bin/test-verify-pr.sh ;
  bash bin/test-gate-baseline.sh ; bash bin/test-slot-parallelism.sh ; python3 bin/test-rules.py
  (las que existan; algunas estan en scripts/ en vez de bin/)
- La maquina es compartida: no compiles, no uses la CPU.

## LO QUE DEVUELVES
La ruta de los 5 archivos, la salida del validador, el rc de los tests nuevos y de las suites, y una
linea por nodo del grafo. Si algo no lo pudiste hacer, decilo con el error exacto. No inventes.
