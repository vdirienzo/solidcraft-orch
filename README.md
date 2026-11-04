# solidcraft-orch

El orquestador que convierte issues de SolidCraft en PRs mergeados. Es codigo de Bash, Python y
un par de crons: no es una app, es un proceso.

## Que hace

1. Barre el pool de issues del repo por la API (paginado, sin truncar) y filtra: sin kernel, sin
   triage, con cuerpo con contenido real.
2. Verifica que el issue este libre (sin claim, sin PR que lo reclame).
3. Localiza la causa raiz en el codigo. Si la causa esta en solidcore/SMLib, el issue se descarta.
4. Escribe el TEST RED y lo commitea y pushea. Este es el entregable minimo del que busca.
5. Le da al que implementa un brief literal con el codigo a aplicar.
6. El agente commitea, pushea al fork y abre el PR EN DRAFT: el draft es el claim (la regla del
   repo: un draft sin pushes por 72 h puede ser tomado).
7. La cola de gates compila a 2 por vez, con su CARGO_TARGET_DIR propio por slot.
8. gate-baseline.sh separa lo preexistente (KNOWN_FAILING_TESTS + origin/main) de lo nuevo: cuenta
   el veredicto efectivo, no el crudo.
9. pipeline.py pasa el PR a ready y comenta el veredicto.

## Que NO se incluye en el repo (se regenera en cada PC)

`targets/ logs/ locks/ gates/ state/ state.json history.jsonl` — son el estado de una maquina
concreta, no codigo.

## Instalarlo en otra PC

```bash
git clone <este-repo> ~/.local/share/solidcraft-orch
cd ~/.local/share/solidcraft-orch
mkdir -p targets logs locks gates state reports briefs baseline
cp bin/slot-target-dir.sh bin/ 2>/dev/null
```

Variables de entorno (NO van al repo, van en el entorno o en un .env ignorado por git):

```
GH_TOKEN=<un token de GitHub con permiso de push y de abrir PRs>
SOLIDCRAFT_CONTROL_TOKEN=<el token del control del daemon de SolidCraft>
```

Los crons que hay que registrar (todos con --no-agent: no gastan tokens de LLM):

| cron | cada | script | para que |
|---|---|---|---|
| solidcraft-gate-queue | 3 min | gate-queue.sh | drena la cola de gates (2 a la vez) |
| solidcraft-pipeline | 5 min | pipeline.py | corrige bodies, encola gates, pasa a ready |
| solidcraft-nice-compilations | 2 min | nice-compilations.sh | baja la prioridad de las compilaciones nuevas |
| solidcraft-reporte-diario | 10 y 22 | daily-report.py | el reporte, sin LLM |

```bash
hermes cron create --name solidcraft-gate-queue --schedule '*/3 * * * *' \
  --script gate-queue.sh --no-agent --deliver local
hermes cron create --name solidcraft-pipeline --schedule '*/5 * * * *' \
  --script pipeline.py --no-agent --deliver local
```

## Las reglas que importan (y que estan en RULES.md)

- Un fallo preexistente en origin/main NO es una regresion: el gate separa lo preexistente de lo
  nuevo y lo que cuenta es el veredicto efectivo.
- El gate usa el mismo set de features que upstream (por eso el scope incluye solidcraft-cli:
  sin el, la feature smlib no esta activada y salen miles de fallos falsos).
- `Changes a default: no` es la forma EXACTA que exige el CI upstream.
- Un test de regresion va en el archivo de test del AREA, nunca en un archivo por bug (#3226).
- Dos compilaciones pesadas como maximo, y cada una con su CARGO_TARGET_DIR.
- CARGO_INCREMENTAL=0, o el sccache no sirve de nada.
- Nada de force-push a origin, nunca cambiar de rama en el checkout principal, y nunca editar un
  script que se este ejecutando.

## Pruebas

Las suites de `bin/test-*.sh` y `bin/test-rules.py` tienen que dar rc=0. Correlos antes de
commitear cualquier cambio del orquestador.
