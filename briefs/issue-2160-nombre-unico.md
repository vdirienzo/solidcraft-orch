# Brief: #2160 - rename y add_feature aplican reglas distintas de unicidad de nombres

**Objetivo unico: que un nombre no se pueda usar dos veces, se acepte por donde se acepte.**

El issue #2160 esta ABIERTO y LIBRE (confirmado con claim-race.sh: sin claim, sin PR que lo
reclame, no es de kernel).

## La causa raiz (esta localizada; no la re-derives)
- `crates/engine/src/cmd/edit.rs:297`: `rename` RECHAZA cualquier nombre que ya este usado por
  otra feature.
- `crates/doc/src/document.rs:3927`: `add_feature` solo rechaza duplicados para los PLANOS: un
  nombre repetido en otro tipo de feature se cuela.
O sea: la misma regla de unicidad esta implementada dos veces, y las dos copias no coinciden. El
sintoma del issue es que un nombre que `rename` no acepta, `add_feature` lo acepta.

## Que hacer (el trabajo de diagnostico es tuyo, el fix tambien)
1. Leé las dos implementaciones y el resto del crate, y decidí cual es la REGLA CORRECTA. La
   evidencia: el doc de los comandos, los tests existentes de add_feature y de rename, y el
   criterio del repo (AGENTS.md y skills/solidcraft-commands/). La regla correcta es la que el
   resto del crate ya asume.
2. Si las dos funciones tienen que quedar IGUALES, unificá la validacion en un solo lugar (un
   helper compartido) y que las dos lo usen. No dupliques la regla por tercera vez.
3. TEST RED PRIMERO (aun no existe): un test que falle con el error real del issue (un nombre
   duplicado que hoy se cuela por add_feature). Correlo y PEGA el mensaje exacto. Sin RED no hay
   entrega.
4. ```
   cd /home/user/solidcraft-wt/issue-2160
   git fetch origin && git checkout -b fix/issue-2160-nombre-unico origin/main
   export CARGO_TARGET_DIR=/home/user/.local/share/solidcraft-orch/targets/slot-2160
   export CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=4
   ```
   Corrélo bajo systemd-run con memoria (el cgroup de Hermes es de 4 GiB y mata el build):
   systemd-run --user --scope --quiet --unit=sc2160 -p MemoryMax=24G bash -lc 'cd /home/user/solidcraft-wt/issue-2160 && ... cargo test -p solidcraft-engine --profile ci --lib <test> -- --nocapture'
   Ojo: solidcraft-engine compila solidcore desde git y la primera build tarda 10+ min.
5. Implementa, testea, y despues corre los tests del doc y del engine afectados y reporta cuantos
   pasan/fallan. Que el cambio NO rompa el caso legitimo (renombrar una feature a un nombre que
   ella misma tiene).
6. cargo fmt --check y cargo clippy -p solidcraft-engine --all-targets --profile ci -- -D warnings
7. ```
   git add <los archivos que tocaste, uno por uno, NO git add -A>
   git commit -m "Doc: one rule for the uniqueness of a feature name, shared by rename and add_feature (#2160)"
   git push fork fix/issue-2160-nombre-unico
   ```
   NUNCA a origin. NO abras PR: el orquestador lo publica.
8. NO corras el gate: lo corre la cola del orquestador.

## Reglas
- El test de regresion va en el archivo de test del AREA, nunca en un archivo por bug (AGENTS.md:24).
- Reemplazo atomico (os.replace / mv). No toques /home/user/solidcraft (el checkout principal), no
  hagas rebase, no toques origin, no toques los scripts del orquestador, no uses pkill.
- La maquina es compartida: CARGO_BUILD_JOBS=4, target dir propio, un build a la vez.
- Si la regla correcta NO se puede determinar con la evidencia del repo (o sea, si es una decision
  de producto), NO la fuerces: implementa lo que la evidencia diga mas fuerte, y en el informe
  explica que habria que decidir, con las dos opciones y cual recomendas.

## Que hay que devolver
Cual era la regla correcta y con que evidencia lo determinaste, el mensaje EXACTO del fallo del
RED, el comando y la salida despues, cuantos tests pasan y fallan, el SHA y la rama. No inventes
resultados.
