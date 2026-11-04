# Auditoría de tokens — 02-11

Pregunta: por qué gastamos el doble que hace dos días.

## El cuadro (medido, no estimado)

### Por día, en el log del agente (`~/.hermes/logs/agent.log*`, rotado)

| día | sesiones | llamadas LLM | prompt tokens | prompt medio |
|---|---|---|---|---|
| 30-10 | 10 | 41 | 855.684 | 20.870 |
| 31-10 | 15 | 35 | 725.902 | 20.740 |
| 01-11 | 23 | 74 | 1.626.685 | 21.982 |
| 02-11 | 20 | 79 | 1.686.397 | 21.346 |

**El prompt por llamada NO creció (20.8k → 21.3k, +2%).** El gasto subió por
**más llamadas** (35 → 79, ×2.3) y **más sesiones** (15 → 20). Es más trabajo, no
un contexto más caro.

### El cron del reporte diario (`usage_audit.jsonl`)

| corrida | prompt | completion | total |
|---|---|---|---|
| 31-10 23:22 | 261.146 | 13.156 | 274.302 |
| 02-11 01:09 | **1.545.019** | 51.250 | 1.596.269 |
| 02-11 13:06 | **1.457.406** | 22.510 | 1.479.916 |

El otro cron del sistema, el que hace una sola cosa: **14.673 prompt + 3 completion**.
El nuestro costaba **100x** eso. Dos corridas por día → ~3M de tokens que no
producían nada que un script no hiciera mejor.

### Dentro de una petición real (request_dump de 1.09 MB, 433 mensajes)

- assistant: 597.5 KB (**59.6%**) — mis propios mensajes: los briefs, uno tras otro, para siempre.
- user (los tool results): 404.5 KB (40.4%)
- system + tools: ~87 KB

## Los gaps, y lo que se hizo

### Gap 1 — el cron del reporte gastaba 1.5M por corrida · CERRADO
Causa: abría una sesión de Hermes, corría 6 comandos y redactaba el reporte a mano;
cada llamada reenviaba el contexto entero.

Fix: `bin/daily-report.py` (en `~/.hermes/scripts/`) recolecta y redacta sin LLM, y
el job quedó en modo no-agent:
`hermes cron edit ed93273c33e1 --script daily-report.py --no-agent --deliver origin`

Verificado con un job de prueba local (luego eliminado): la corrida dio `ok` y el
usage audit **no registró ninguna línea** para ese job → 0 tokens de modelo.
El script también deja el reporte en `reports/latest.md` y `reports/daily-<fecha>.md`.

Ahorro: ~1.48M de prompt y ~40K de completion por corrida, dos veces por día.

### Gap 2 — mis briefs ocupan el 60% del contexto · PROCEDIMIENTO CAMBIADO
Un brief de 5 KB enviado como texto queda en el historial para siempre y se reenvía
en cada turno. El brief va ahora a disco: el dispatch lleva el path y el agente lo
lee. En el contexto, ~100 bytes en vez de 5.000.

### Gap 3 — la compresión disparaba tarde · CERRADO
`compression.threshold` 0.50 → **0.30**. Con la ventana de 1M, comprimir al 50%
dejaba arrastrar hasta ~500k tokens (~2 MB) por llamada; el peor caso baja a ~300k.
El destino post-compresión sigue siendo `target_ratio: 0.20` (200k). Backup en
`~/.hermes/config.yaml.bak-20261102-ctx`.

### Gap 4 — el arrastre histórico de esta sesión
3.7 MB / 5532 mensajes, mayormente salidas de verificaciones ya hechas. Es lo que
`compression.threshold` acota y lo que la regla "la conversación es efímera, el
estado va a disco" evita de ahora en adelante.


## El hallazgo que explica el resto: 87 KB fijos por llamada

De una peticion real (request_dump de 1.09 MB): 1089 KB de JSON, de los cuales
1002 KB son los mensajes y **~87 KB son el system prompt + los schemas de las
herramientas**. Y el prompt MEDIO medido en el log es de 21k tokens ~= 84 KB.

O sea: **casi todo el prompt es el system prompt**, y el historial ya esta
comprimido (por eso el prompt medio no crecio). Ese bloque fijo se reenvia en
CADA llamada:

- 79 llamadas x 87 KB = **6.9 MB por dia**, que es exactamente el gasto medido.
- Un subagente que hace 250 llamadas paga 21 MB de input SOLO en system prompt.
  El que leyo 342 veces (la feature #9866) costo ~30 MB antes de morir sin escribir.

Por eso el numero de llamadas por subagente es la palanca de costo, mas que el
tamano del brief: un brief de 5 KB son 0.12 MB reenviados; 200 llamadas de mas
son 17 MB.

**Regla que sale de aca:** todo subagente lleva un tope explicito (tiempo y
llamadas). Un subagente que pasa de ~80 llamadas esta fallando, no trabajando:
casi siempre es el de la parálisis de lectura, y se lo puede matar antes de que
gaste.

## Lo que NO se hizo y por qué

- **Bajar la ventana del modelo a 500k**: en Hermes no existe la clave
  `context_length`; el límite lo declara el provider. El `threshold` produce el
  mismo ahorro sin depender de eso.
- **Menos subagentes en paralelo**: ahí está el crecimiento real (más llamadas),
  pero es el trabajo pedido, no un desperdicio. Lo que sí se controla es el costo
  por llamada.
- **Acortar el system prompt**: son ~87 KB fijos por petición, y se pagan en todas.
  Bajarlo exige tocar Hermes, no la config.
