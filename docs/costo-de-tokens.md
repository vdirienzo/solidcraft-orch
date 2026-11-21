# El costo de los tokens: la medicion completa

Todo lo de abajo son `usage` reales devueltos por la API de MiniMax
(`https://api.minimax.io/anthropic/v1/messages`, modelo `MiniMax-M3.1-Flash`), no estimaciones.
El informe largo esta en `reports/auditoria-tokens-2026-11-03.md`.

(2026-11-21) Las mediciones son de cuando el agente corria en hermes. Los numeros del proveedor
siguen valiendo; los consejos que eran perillas de hermes (tope de iteraciones, herramienta de
codigo, umbral de compresion, crons con `--no-agent`) se cambiaron por los de opencode y el
crontab.

## Lo que se midio

Contra MiniMax-M3.1-Flash (input $0,15/M, OUTPUT $0,60/M, cache read $0,015/M), en una sesion
real de 16 llamadas: input $0,0117 (20 %), output $0,0157 (27 %), cache $0,0313 (53 %). El
proveedor cachea el request ENTERO solo (277.760 de cache read sobre un request de 993 KB), asi
que el tamano del request no es el costo: el costo son los MISSES del cache y el OUTPUT.

Un agente que da 250 vueltas cuesta unos $1,17 y no entrega nada (625k tokens de output, 32,5M
de cache read y tres compresiones del contexto de ~$0,04 y 104 segundos cada una; cada
compresion rearma el prompt de sistema y rompe el prefijo del cache).

El cache expira entre 7 y 17 minutos de silencio (medido: vivo a los 7 min, muerto a los 17).
Un miss cobra el prefijo entero a precio de input, 10 veces el del cache. Una compilacion de
cargo tarda 10 a 25 minutos, asi que cada una es un miss seguro.

## En cada despacho

- **El techo es de TIEMPO**: `AGENT_TIMEOUT_MIN` (180 min si `$LOOP_DIR/config.env` no dice
  otra cosa, leido por `bin/agent-env.sh`). `bin/dispatch-slot.sh` lo aplica con
  `timeout --kill-after=120`, y el log del slot dice "techo de tiempo" cuando el agente sale
  con 124. Un agente trabado ya no tiene el slot ni quema tokens para siempre.
- **Las lecturas, en pocas llamadas**: pedirle al agente que lea lo que necesita en una sola
  llamada (un `bash` con varios `sed -n`/`grep` acotados), no un archivo por llamada. La
  historia crece unos 3k tokens de output mas el resultado por llamada, y 250 llamadas son
  750k tokens y tres compresiones.
- **El trabajo pesado (la compilacion) al FINAL**, no en el medio.
- **Un resumen CORTO**: vuelve al contexto del orquestador. El veredicto del brief es un JSON
  fijo; lo largo queda en el disco.
- **El costo se lee del log, no del resumen**: `--format json` deja los eventos del turno, con
  su uso de tokens, en `logs/<N>-wave.jsonl` (y lo que dice `dispatch-slot.sh` en
  `logs/<N>-wave.log`). Los dos se agregan: un re-despacho no borra el turno anterior.
- **Nunca retomar una sesion fria**: `CONTRIBUTING.md` de upstream dice "don't `--resume` one
  whose prompt cache has gone cold (it re-reads the whole history at full price)". Pasados los
  ~15 minutos de silencio, `--continue`/`--session` paga toda la historia a precio de input. El
  turno nuevo arranca del brief y de lo que ya esta pusheado en el fork.

## Los trabajos recurrentes no cuestan nada cuando son scripts

Un trabajo programado que abre una sesion de agente gasta el contexto entero en cada corrida:
el reporte diario como agente costaba ~1,5M tokens de prompt por corrida. El mismo trabajo
como script gasta CERO tokens de modelo: el script junta los datos Y los redacta.

Los crons del loop son el crontab del usuario (`bin/crons.txt` → `bin/install-crontab.sh`). Tres
detalles deciden si un job funciona de verdad:

- el crontab tiene que tener `PATH` (cron arranca con `/usr/bin:/bin` y ahi no estan `gh`,
  `opencode` ni `cargo`), y cada script corre por su interprete (`python3` para un `.py`);
  `bin/preflight.sh` avisa si falta;
- un cron llama al script SIN argumentos, asi que su rama por defecto tiene que ser la util:
  un script que solo imprime su uso deja al job sin hacer nada, en silencio, en cada tick;
- la salida va a `logs/cron-<job>.log`: un job que falla sin log falla para siempre.

La misma forma vale para el mantenimiento de la caja (bajar la prioridad de las compilaciones,
drenar la cola de gates): cada uno es un script, corre cada pocos minutos y hace su trabajo en
la rama por defecto.

## Un agente que muere se paga DOS veces si se re-despacha

Un agente que llega al techo casi siempre ya commiteo y pusheo: el techo se alcanza al FINAL de
la corrida, y lo que se corta es el resumen, no el trabajo. Un resumen cortado es una razon para
ir a LEER el worktree y el head del fork, nunca para despachar un reemplazo: el reemplazo
re-deriva un diseno ya resuelto y quema su presupuesto antes de escribir nada.
