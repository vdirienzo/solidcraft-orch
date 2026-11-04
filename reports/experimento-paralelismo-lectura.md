# Experimento de paralelismo de los gates (2026-11-04)

## Que se midio
El mismo crate (`solidcraft-sketch` + `solidcraft-doc`, perfil `ci`, el de los gates) con tres
repartos de los 16 cores, 2 repeticiones cada uno, con el sccache medido con `--show-stats`.

| caso | reparto | FRIO (rep 1) | CALIENTE (rep 2) | builds/h frio |
|---|---|---|---|---|
| A | 1 build, 16 jobs | 277s | 27s | 13.0 |
| B | 2 builds, 8+8, EN PARALELO | 354s | 46s | **20.3** |
| C | 2 builds, 8+8, EN SERIE (cache compartido) | 455s | 46s | 15.8 |

## La lectura que importa
- **Sin cache, el paralelo gana**: 2 en paralelo dan 20.3 builds/h contra 15.8 de la
  serie y 13.0 de un solo build con 16 jobs.
- **Un solo build con 16 jobs es la peor opcion**: el paralelismo interno de Rust tiene fases
  seriales (codegen de los crates grandes y el linkeo), asi que 16 jobs no usan la maquina entera
  y el resto de los cores quedan ociosos.
- **Con cache caliente el 2do build es casi gratis**: 23s. El sccache global (el que usa el
  orquestador) es lo que hace que el 2do gate de la cola sea mucho mas rapido que el 1ro.
- **El caso real de la cola es la serie con cache**: el 1ro gate compila frio (277s) y el 2do
  pega en el cache (23s) = 300s por 2 builds = **24.0 builds/h**, que
  es lo mejor de los tres.

## La conclusion
**2 a la vez, pero escalonados**: el 2do slot no tiene que arrancar en el mismo instante. Si arranca
despues de que el 1ro ya cacheo las dependencias compartidas (los 21 paquetes del workspace, de los
que un issue通常 cambia uno o dos), el 2do gate pega en el sccache y sale en 23s en vez de 277s.

Eso es lo que falta en la cola actual: `gate-queue.sh` lanza el 2do gate a los 20 s del primero.
Con un delay de 60-90 s, el 2do gate finds the cache warm.

Y la regla que queda: **1 solo build con 16 jobs nunca**. El error caro no es la cardinalidad, es
compilar dos veces lo mismo (5 compilaciones simultaneas del mismo workspace con smlib: 0 hits).
