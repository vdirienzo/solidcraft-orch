# Medición del comportamiento de los subagentes — 02-11

Fuente: 132 transcripts completos en `/home/user/.hermes/cache/delegation/live/*/task-*.log`.
CSV con la fila por subagente: `reports/agentes-metricas.csv`.

## El número grande

| | |
|---|---|
| subagentes lanzados | **132** |
| lecturas totales | **54.091** |
| escrituras totales | **1.946** |
| ratio lectura/escritura | **28 : 1** |
| llegaron al tope de iteraciones | 32 |
| interrumpidos | 49 |
| fallidos | 2 |
| completaron | 42 (32%) |
| **completaron Y dejaron commit** | **13** |
| completaron Y dejaron PR | 20 |
| completaron Y dejaron ambos | 6 |
| no escribieron nunca | 35 |
| leyeron >25 veces y escribieron 0 | **32** |

## Por categoría

| categoría | n | lecturas | escrituras | ratio | commit | PR | completaron | murieron |
|---|---|---|---|---|---|---|---|---|
| issue | 107 | 38.359 | 1.543 | 25 | 27 | 20 | 32 | 69 |
| **feature** | **17** | **11.768** | **261** | **45** | **2** | **2** | **4** | **13** |
| evidencia | 5 | 2.251 | 91 | 25 | 1 | 4 | 5 | 0 |
| búsqueda | 3 | 1.713 | 51 | 34 | 0 | 0 | 1 | 1 |

**Las features son el agujero**: 13 de 17 mueren, y leen 45 veces por cada escritura.
Un issue se resuelve con 25 lecturas por escritura.

## Lo que funciona (ratio lectura/escritura < 8)

| subagente | escr | lect | commit | PR | tarea |
|---|---|---|---|---|---|
| deleg_3ddb905e | 29 | 170 | sí | sí | inventario de worktrees, ramas y PRs |
| deleg_97a18525 | 28 | 153 | sí | sí | rebasar la rama de un PR abierto |
| deleg_41f47dc5 | 20 | 129 | sí | — | **escribir en UN archivo (`distribute.rs`) con la matemática ya escrita** |
| deleg_754bcbeb | 86 | 636 | — | — | completar el `gc-disk.sh` del propio loop |
| deleg_b4e36260 | 96 | 534 | — | — | conectar el guard de claims al publisher |
| deleg_be329a7b | 63 | 196 | — | — | agregar un cap al GC de disco |

El patrón: **el andamiaje del loop y los archivos con el contenido ya escrito**.

## Los tres errores del loop, con el número

### 1. "completed" no significa "entregó"
De los 42 que completaron, solo 13 dejaron commit y 6 dejaron commit **y** PR.
El estado del subagente no es un termómetro de productividad: el loop lo registra como
éxito y sigue. **Falta una verificación post-agente**: dado un slot, comprobar
commit + push + PR, y marcar el slot como `entregó` o `no entregó`.

### 2. El tope de iteraciones se gasta en leer, no en escribir
Los 32 que llegaron al tope leyeron **765 veces en promedio** y solo 6 dejaron
commit. El tope de iteraciones no es un límite de trabajo útil: es un límite de
exploración. Con 765 lecturas, el agente nunca iba a escribir.

### 3. Las features se despachan sin el contenido que hay que escribir
17 features, 2 commits, 13 muertes. Es la categoría peor. El método que funciona
(leer 129 veces y escribir 20 en un archivo con la matemática ya escrita) se aplicó
a features donde había que **inventar** la implementación: 45 lecturas por escritura
y la nada.

## Las reglas que salen de los números

1. **Un brief = un archivo = un criterio binario.** Con contenido dado (la matemática,
   la API, el diff), el agente escribe. Sin contenido dado, lee hasta morir.
2. **Un tope de lecturas, no solo de iteraciones.** Pasadas ~80 lecturas, el agente
   va a morir: matarlo antes cuesta 1 minuto de máquina y no 30.
3. **El brief va a disco.** 5 KB de brief enviado como texto se reenvían en cada
   turno; en disco son 100 bytes en el contexto.
4. **El estado del subagente no es el resultado.** Hay que verificar el commit.

## Lo que este informe no cubre

Los tres subagentes de análisis que se despacharon en paralelo (agentes, código del
loop, gates) escriben sus informes en:

- `reports/loop-agentes.md` — el detalle por subagente
- `reports/loop-codigo.md` — los bugs de los scripts del loop
- `reports/loop-gates.md` — el costo y la eficiencia del gate
