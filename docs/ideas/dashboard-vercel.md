# Idea: pagina de avance en Vercel (2026-11-04) — NO IMPLEMENTADA

Decidido en conversacion, pendiente de implementacion. **No se hizo nada todavia.**

## Que se quiere
Una pagina que muestre el avance: issues abiertos, PRs presentados, PRs mergeados.

## El camino elegido (es el del usuario, con dos ajustes)

1. **No hace falta "pushear a Vercel".** Con la integracion de Git, Vercel clona el repo y cada
   push a `main` dispara el redespliegue solo. El push al repo ES el deploy.
2. **El artefacto es un JSON de datos, no la pagina.** El cron genera `dashboard/data.json`; la
   pagina es un HTML estatico que hace `fetch('data.json')` y dibuja. Dato y presentacion se tocan
   por separado, el fetch es same-origin contra el CDN de Vercel, y no hay build step.

## De donde salen los datos
- Issues abiertos, PRs abiertos, PRs mergeados: la API de GitHub (2-3 requests extra:
  `gh api search/issues` da el conteo exacto sin truncar).
- Que issues atacamos nosotros, que PRs son nuestros y en que estado: el `state.json` (ya partido
  por concepto en `state/`).

El generador reusa el cron que ya existe: `daily-report.py`, que corre a las 10 y las 22 con
`--no-agent` (0 tokens de LLM) y ya consulta `gh pr list`.

## Lo que se descarto
Una serverless function de Vercel consultando la API de GitHub en cada visita: expone un token,
consume el rate limit de GitHub por visita, y para tener los datos NUESTROS necesita el token
igual. Con el JSON commiteado, todo eso desaparece.

## Frecuencia
Es la del push, que es la del cron (2 veces al dia). Para actualizarla mas seguido se sube la
frecuencia del cron; no hay que tocar Vercel.

## Decisiones pendientes (NO tomadas)
1. **Publica o privada la pagina.** Depende de si importa que se vean que issues estamos atacando.
   - Publica: repo publico nuevo (p.ej. `solidcraft-dashboard`), sin token de GitHub en Vercel ni
     autenticacion: la pagina es publica por URL.
   - Privada: el repo `solidcraft-orch` y Vercel Protection (requiere plan Pro).
2. **En que repo.** Si es un repo publico nuevo, el cron tiene que pushear a dos repos.

## El plan cuando se implemente
1. `dashboard/data.json`: el esquema de los datos (issues abiertos, en curso, PRs abiertos y
   mergeados con fecha, y un historico por semana).
2. `dashboard/index.html`: HTML + CSS + JS estaticos, sin framework, que consume el JSON.
3. Vercel: conectar el repo, output directory `dashboard`, framework "Other". Cada push a `main`
   redespliega.
4. `daily-report.py` (o un script aparte que el cron llama) genera el JSON y lo commitea.
