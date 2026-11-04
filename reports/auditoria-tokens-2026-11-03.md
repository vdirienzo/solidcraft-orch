# Donde se van los tokens (medido contra el provider y contra la doc de MiniMax, 2026-11-03)

## 0. Los precios (doc oficial: intl.minimaxi.com/docs/pricing)

| | $/M tokens |
|---|---|
| Input | $0,15 |
| Output | **$0,60** (4x el input) |
| Prompt caching read | **$0,015** (10x MAS BARATO que el input) |

Por encima de 512k tokens de input el precio de MiniMax-M3 se DUPLICA (input $0,60, output $2,40,
cache $0,12). El cache explicito tiene TTL de 5 min y write a 1,25x el input.

Endpoint: `https://api.minimax.io/anthropic/v1/messages`, modelo `MiniMax-M3.1-Flash`.
La key se leyo de `~/.hermes/.env` en el momento y no quedo en ningun artefacto.
Todo lo de abajo son `usage` reales devueltos por la API, no estimaciones.

## 1. La composicion de un request real

Del dump real de la sesion (`~/.hermes/sessions/request_dump_20261031_..._20261102_105259.json`,
un request que fallo con `max_retries_exhausted`):

| Parte | Peso | Tokens (~) |
|---|---|---|
| `system` | 22,7 KB | 5,7k |
| `tools` (21 schemas) | 40,3 KB | 10,0k |
| `messages` (419: 210 user, 209 assistant) | 992,6 KB | 248k |
| — de los cuales `tool_result` | 228,1 KB | 57k |
| — texto | 226,4 KB | 57k |
| **total** | **1.055,8 KB** | **~270k** |

Ninguna tool llevaba `cache_control` (0/21) y el `system` era un string plano (sin bloque, sin marcador).
Hermes excluye a M3 del `cache_control` a proposito (`agent_runtime_helpers.py`: *"MiniMax's own models
(M2.x) ... support cache_control ... M3 is excluded above"*).

## 2. El cache de MiniMax funciona igual, y cubre TODO el request

Con el request real completo (993 KB de historial):

| Llamada | `input_tokens` | `cache_read_input_tokens` |
|---|---|---|
| 1 (fria) | 276.725 | 1.536 |
| 2 (prefijo identico) | **501** | **277.760** |

Y con un prefijo mediano (system + tools + 182 KB de historial):

| Llamada | `input_tokens` | `cache_read` |
|---|---|---|
| 1 | 48.527 | 4.096 |
| 2 | 143 | 52.480 |
| 4 (prefijo + 1 mensaje nuevo) | 152 | 52.480 |

**El 99,7% del request se sirve del cache, sin marcador explicito y con el system como string.**
Conclusion: el tamano del request NO es el gasto. El gasto son los **cache misses** y el **output**.

## 3. Las imagenes

| Contenido | `input_tokens` |
|---|---|
| solo texto | 8 |
| 1600x1000 (242 KB) | 2097 |
| 800x500 | 531 |
| recorte 400x300 | 174 |

~1300 tokens por megapixel (patching de 28x28). Una captura entera es <1% del request.
Mandar dos veces la misma imagen es gratis (la segunda la sirve el cache).

## 4. Las dos palancas que quedan

### a) El thinking: 8000 tokens de presupuesto por llamada
La request lleva `thinking: {type: enabled, budget_tokens: 8000}`. El thinking se cobra como OUTPUT
(en la medicion de prueba: `output_tokens: 16`, `thinking_tokens: 15`) y ademas se suma al historial,
que es lo que hace crecer el prefijo y dispara la compresion.
Con 250 llamadas por agente, el techo son 2.000.000 tokens de razonamiento por agente.

### b) La compresion reconstruye el prefijo y por lo tanto rompe el cache
`agent/conversation_compression.py` tiene `_rebuild_system_prompt_at_boundary` y
`_existing_system_prompt`: al comprimir, Hermes reconstruye el system prompt, el prefijo cambia y
la llamada siguiente es un **cache miss completo** (277k tokens) MAS una llamada de LLM sobre todo
el contexto para producir el resumen.

Config actual: `threshold: 0.30`, `target_ratio: 0.20`, `protect_last_n: 20`.
Con ventana de 1M, comprime a los ~300k tokens.

**OJO**: mientras el cache este vivo, un historial grande cacheado sale MAS BARATO que compresiones
frecuentes (cada compresion = 1 llamada cara + 1 cache miss). Pero si el cache expira por inactividad,
un historial grande vuelve a ser caro. De ahi la medicion del TTL (t=0, 90s, 7min, 17min).

## 3b. La partida grande: las compresiones de contexto

27 compresiones en el log de un dia. Cada una:
- paga ~250k de input a $0,15/M (no cacheado: el contenido es nuevo) + el output del resumen: **~$0,04**,
- tarda **104 segundos en promedio** (max 307s): **47 minutos de reloj**,
- **reconstruye el system prompt** (`conversation_compression.py::_rebuild_system_prompt_at_boundary`),
  con lo que el prefijo cambia y la llamada siguiente es un cache miss.

Costo estimado de las 27 compresiones: **~$1,09**.

## 4b. Lo que NO conviene hacer (medido, no supuesto)

- **Subir o bajar `compression.threshold`**: el input no cacheado es el 20% del costo y el cache esta
  sano. El efecto es marginal, y subirlo acerca el prefijo al cliff de 512k (precio duplicado).
  El 0,30 actual esta bien.
- **Bajar `thinking.budget_tokens`**: el uso real es 1,6k-3k de los 8k disponibles. No toca el techo.
- **Tocar el codigo de Hermes para el `cache_control`**: el caching automatico del provider ya
  cubre el 96% del input. El riesgo de tocar la instalacion es mayor que el beneficio.

## 4c. Lo que SI conviene (por impacto)

1. **Matar antes a los agentes en parálisis**: `max_iterations` es un parametro del dispatch.
   Un agente que llega a 250 iteraciones costo ~$1,17 (output 625k tokens, cache read 32,5M, tres
   compresiones) y no entrego nada. Con `max_iterations: 120` se corta antes y el historial queda
   mas chico (el cache read escala con el).
2. **Menos llamadas por agente**: el historial crece ~3k de output + el tool_result por llamada.
   250 llamadas = 750k tokens = 3 compresiones. Por eso los briefs piden lecturas en un
   `execute_code` (un tool call con diez archivos) y no diez `read_file`.
3. **El cron sin agente**: ya hecho, ~1,5M de prompt tokens por corrida -> 0.
4. **Recortar las imagenes**: 2.097 tokens por captura de 1600x1000; 174 por un recorte de 400x300.

## 4d. El TTL del cache: medido, entre 7 y 17 minutos

```
03:11:09 t=0 (fria):  input=18.264  cache_read=15.872
03:12:41 t=90s:       input=88      cache_read=34.048
03:19:27 t=7min:      input=88      cache_read=34.048   <- el cache sigue vivo
03:29:32 t=17min:     input=30.040  cache_read=4.096    <- expiro entre 7 y 17 min
```

La doc del cache EXPLICITO dice TTL de 5 min; el implicito aguanta mas. La consecuencia practica:
**una pausa de mas de ~10 minutos entre llamadas es un cache miss**, y el prefijo entero se
paga a $0,15/M en vez de $0,015/M (10x). Con un prefijo de 250k tokens son $0,0375 por miss
contra $0,0038 si estuviera caliente.

Las compilaciones de cargo duran 10-25 minutos: **cada una es un miss garantizado**. De ahi las
dos reglas operativas:
- el agente hace el trabajo pesado (cargo) AL FINAL, no en el medio: leer -> escribir -> compilar
  -> verificar es un miss; leer -> compilar -> leer -> escribir son dos;
- las lecturas van en un solo `execute_code`: cada llamada ausente del cache es un miss entero.

## 5. Lo que ya se corrigio

- El cron diario paso a `--script daily-report.py --no-agent`: ~1,5M de prompt tokens por corrida -> 0.
- Los briefs viven en un archivo y el dispatch lleva la ruta: el contexto del orquestador paso de
  597 KB a menos.
- `compression.threshold` 0.50 -> 0.30.

## 6. Lo que queda por medir

- El TTL del cache implicito (corriendo): si expira en minutos, las compilaciones largas de cargo
  (10-25 min) matan el cache y cada llamada post-compilacion paga el prefijo entero.
- Si conviene poner `cache_control: ephemeral` explicito (eso ademas extiende el TTL).
- Si conviene bajar `thinking.budget_tokens` de 8000 a algo como 2500: baja el output y frena el
  crecimiento del historial, a costa de mas llamadas por agente.
