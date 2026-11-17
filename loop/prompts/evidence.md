# sc-evidence — evidencia visual

Generás evidencia del cambio: capturas **antes y después**.

## Comandos que podés correr (tu sandbox es estricto)

Sólo estos pasan: `solidcraft-cli *`, `Xvfb *`, `cargo run *`,
`bash /home/user/.local/share/solidcraft-loop/bin/run-app.sh <args>` (con
argumentos: el patrón permitido exige un espacio y al menos un argumento),
`bash /home/user/.local/share/solidcraft-loop/bin/capture-shortcuts.sh <args>`,
`bash /home/user/.local/share/solidcraft-loop/bin/capture-visibility-evidence.sh <args>`,
`bash /home/user/.local/share/solidcraft-loop/bin/capture-sketch-dof-evidence.sh <args>`,
`bash /home/user/.local/share/solidcraft-loop/bin/build-app-pair.sh <args>`,
`mkdir -p /home/user/.local/share/solidcraft-loop/evidence*`, `git checkout *`,
`git status *`, `git log *`, `git rev-parse *`, `git fetch *`, `cat *`, `date *`,
`echo *`, `tail *`, `head *`, `ls *`,
`nc 127.0.0.1 *`, `socat - TCP:127.0.0.1:*`, `curl 127.0.0.1:*`.

Los comandos compuestos (`script.sh; echo "exit=$?"`, `script.sh 2>&1 | tail -20`)
pasan: cada parte tiene que estar en la lista.

Los cinco scripts del loop también pasan **con variable de entorno** delante
(`env VAR=... bash <script> ...`, y lo mismo sin el `env`), que es lo que
necesitás para apuntar la app a un binario concreto:

```
env SOLIDCRAFT_BIN=<binario> bash /home/user/.local/share/solidcraft-loop/bin/run-app.sh --sample --control <PUERTO>
```

**`cp` no está permitido**: el PNG se escribe **directo** en la ruta destino (el
tool MCP `screenshot` acepta `path`, `solidcraft-cli snapshot` acepta `--out`,
y la app escribe en el `path` del `ui.screenshot`). No hace falta copiar nada.

## Where you work: the per-issue worktree

You work in the **worktree the supervisor put you in**: your CWD **is** it
(`/home/user/solidcraft-wt/issue-<N>`), with the branch of the issue already
checked out. `git checkout *`, `git fetch *`, `git log *` and `git rev-parse *`
work there, without `-C`.

**Do not use `/home/user/solidcraft-evidence`**: that directory does not exist
and adding a worktree is denied in your sandbox (that is why the ledger of
2026-10-24 says "evidencia: n/a").

## Procedimiento

1. **Decide the evidence from the diff** (mechanical, do not guess):

   | the diff touches | evidence |
   |---|---|
   | `crates/ui-egui`, `crates/render` | **PNG before/after** of the app |
   | `crates/engine`, `crates/doc` | the output of `solidcraft-cli snapshot` (headless), **no app build** |
   | `crates/kernel` | **none**: `area:kernel` is excluded from the funnel |
   | only `docs/` or `*.md` | **none**: "Changes with no useful observable behavior do not need screenshot or video evidence" (`AGENTS.md`) |

   The CLI snapshot is the cheap path and it is the one that fits a turn:
   `solidcraft-cli snapshot <script.json> --out <ruta>` renders the geometry
   headless, with no LTO build of the app (~35 min saved). Use the PNG path only
   when the change is visible in the window.
2. Si es observable, armá un ejemplo **público y sin datos privados**.
3. Levantá la app con el entorno headless ya montado (el script levanta Xvfb si
   no está vivo y genera el token del canal de control):

```
bash /home/user/.local/share/solidcraft-loop/bin/run-app.sh --sample --control <PUERTO>
```

`<PUERTO>` es un puerto libre que elegís vos. **Siempre con argumentos**: el
comando sin argumentos no matchea lo permitido y el sandbox lo deniega.

El stack gráfico (Xvfb + lavapipe) ya está configurado en `config.env`:
`DISPLAY=:99`, `VK_ICD_FILENAMES`, `SOLIDCRAFT_GPU=cpu`. Para comandos sin
display usá `solidcraft-cli` (p. ej. `solidcraft-cli snapshot`), que es el
camino rápido para geometría.

4. Capturá **antes** (rama base / commit original) y **después** (tu rama), en el
   worktree de evidencia. Ya no hace falta volver a la rama del issue: el
   checkout principal lo sigue usando `sc-implement`.
5. **Capturar la ventana real**: el canal de control habla JSON lines sobre
   `127.0.0.1:PORT` y el token del launch está en
   `~/.local/share/solidcraft/control/<PUERTO>.token`.

   **Ya hay un script que hace la receta completa** (verificada):

   ```
   bash /home/user/.local/share/solidcraft-loop/bin/capture-shortcuts.sh <command-id> <salida.png> [tecla] [puerto]
   ```

   Imprime en stdout la tecla ligada (la aserción para el cuerpo del PR) y
   escribe el PNG. Ejemplo:

   ```
   bash /home/user/.local/share/solidcraft-loop/bin/capture-shortcuts.sh \
     sketch.rectangle.center /home/user/.local/share/solidcraft-loop/evidence/4582-after.png ShiftLeft
   ```

   **Y los tres scripts nuevos** (instalados en el `bin/` del runtime), que
   hacen el par antes/después **sin** que tengas que manejar el canal de control
   a mano:

   ```
   bash /home/user/.local/share/solidcraft-loop/bin/build-app-pair.sh <worktree> <rama> <sha-antes> [tag]
   bash /home/user/.local/share/solidcraft-loop/bin/capture-visibility-evidence.sh <binario> <salida.png> [display] [puerto]
   bash /home/user/.local/share/solidcraft-loop/bin/capture-sketch-dof-evidence.sh <binario> <salida.png> [display] [puerto]
   ```

   - `build-app-pair.sh` compila la app **dos veces** en el worktree (el tip de
     la rama y su padre) y deja los dos binarios en
     `/home/user/.local/share/solidcraft-loop/evidence/<tag>-app-after` y
     `<tag>-app-before`. El `<tag>` sale del número del issue en el nombre de la
     rama. Si un build falla, el script **falla**: no te da un binario viejo
     como si fuera el bueno.
   - `capture-visibility-evidence.sh` y `capture-sketch-dof-evidence.sh` levantan
     la app **en su propio display** (`:98`, para no tapar la ventana del loop),
     la manejan por el canal de control y escriben el PNG en la ruta que les
     pases. Mueren la app al salir.

   Ejemplo del par antes/después (un cambio del solver del sketch):

   ```
   # 1. los dos binarios (el tip de la rama y su padre)
   bash /home/user/.local/share/solidcraft-loop/bin/build-app-pair.sh \
     /home/user/solidcraft-wt/issue-5505 fix/issue-5505-sketch-constraint-dof 77665cb5 5505
   # 2. la captura de cada uno
   bash /home/user/.local/share/solidcraft-loop/bin/capture-sketch-dof-evidence.sh \
     /home/user/.local/share/solidcraft-loop/evidence/5505-app-before \
     /home/user/.local/share/solidcraft-loop/evidence/5505-before.png
   bash /home/user/.local/share/solidcraft-loop/bin/capture-sketch-dof-evidence.sh \
     /home/user/.local/share/solidcraft-loop/evidence/5505-app-after \
     /home/user/.local/share/solidcraft-loop/evidence/5505-after.png
   ```

   Los tres scripts aceptan **prefijo de entorno** (`env VAR=... bash <script>`),
   por si necesitás pasarles `LOOP_DIR`, `TARGET_DIR` o `JOBS`.

   Si lo que querés es la app **corriendo** (no sólo la captura), apuntala a un
   binario con la variable de entorno:

   ```
   env SOLIDCRAFT_BIN=/home/user/.local/share/solidcraft-loop/evidence/5505-app-after bash /home/user/.local/share/solidcraft-loop/bin/run-app.sh --sample --control <PUERTO>
   ```

   **Receta verificada** (si tenés que hacer algo que el script no cubre):

   ```
   # 1. la app (una sola instancia: matá la anterior, ver "gotchas")
   bash /home/user/.local/share/solidcraft-loop/bin/run-app.sh --sample --control <PUERTO>
   # 2. el token
   cat ~/.local/share/solidcraft/control/<PUERTO>.token
   # 3. abrir la página de atajos (EDITABLE: es la que tiene el botón "+")
   printf '{"id":1,"method":"ui.prefs","params":{"open":"Keyboard Shortcuts"},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
   #    (la respuesta trae "dialog":"Keyboard Shortcuts": la página está abierta)
   # 4. el botón "+" de una fila VISIBLE
   printf '{"id":2,"method":"ui.at","params":{"handle":"keymap:capture:<command-id>"},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
   #    → [x, y]
   # 5. click en "+" (empieza la captura)
   printf '{"id":3,"method":"ui.click","params":{"x":<x>,"y":<y>},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
   # 6. la tecla que quieras ligar
   printf '{"id":4,"method":"ui.key","params":{"key":"ShiftLeft","shift":true},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
   # 7. la captura
   printf '{"id":5,"method":"ui.screenshot","params":{"path":"<PNG>"},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
   # 8. la aserción textual (para el cuerpo del PR)
   printf '{"id":6,"method":"ui.shortcut","params":{"command":"<command-id>"},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
   #    → {"key":"Shift+ShiftLeft"} antes del fix, {"key":"Shift"} después
   ```

   **Gotchas que ya están resueltos (no los repitas):**

   - **Una sola instancia de la app.** Si queda otra corriendo, su ventana
     **tapa** la tuya y el screenshot responde
     `{"ok":false,"hidden":true,"error":"no frame was presented (window hidden?)"}`.
     Matá la anterior (`pkill -f "solidcraft --sample"`) y levantá una sola.
   - `ui.prefs {"open":"Keyboard Shortcuts"}` abre la página **editable** (con
     el botón "+"). `ui.help {"item":"shortcuts"}` la abre **read-only** (sin
     "+") y además deja el diálogo en read-only: **no la uses** para esto.
   - El `ui.at` de una fila que está **fuera de la pantalla** devuelve un `y`
     enorme (p. ej. 5086) y el click no hitsa nada. Para traer una fila a la
     vista, **filtrá**: click en el cuadro "Filter commands or keys" (arriba de
     la lista) y escribí el texto con `ui.text`:
     ```
     printf '{"id":1,"method":"ui.click","params":{"x":855,"y":232},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
     printf '{"id":2,"method":"ui.text","params":{"text":"center"},"token":"<T>"}\n' | nc 127.0.0.1 <PUERTO>
     ```
     Con el filtro puesto, la fila buscada queda arriba y su tecla se ve en la
     columna "Keyboard Shortcuts".
   - Si la tecla **ya está usada** por otro comando, el diálogo lo dice
     ("Shift is already used by Center Rectangle") y **no** la liga: primero
     `Clear` en la fila que la tiene (el handle `keymap:clear:<command-id>`) y
     después ligala. Si el mensaje de conflicto queda en pantalla, sacalo
     (click en "Cancel" del mensaje) antes de la captura.
   - Para una página que no sea la de atajos: **no hay comando de engine**
     (`ui.*` del engine no existen), pero el **canal de control** sí tiene
     métodos propios (`ui.prefs`, `ui.help`, `ui.window`, `ui.at`, `ui.click`,
     `ui.key`, `ui.text`, `ui.scroll`, `ui.shortcut`, `ui.screenshot`,
     `ui.render`). Si la pantalla no se alcanza, **decilo** y devolvé la
     evidencia que sí se pueda (un render del modelo, o la tabla del
     antes/después).
6. Guardá los PNG **fuera** del repo (el supervisor los publica al final de la vuelta en una rama del fork):

```
/home/user/.local/share/solidcraft-loop/evidence/<N>-before.png
/home/user/.local/share/solidcraft-loop/evidence/<N>-after.png
```

   Al lado de cada PNG queda su hermano **`<nombre>.webp`** (1024 px): es la
   versión que **leés vos**, no el PNG. Los scripts de captura lo escriben
   solos; si no está (porque en la máquina no había conversor), leés el PNG.

   **Cómo se los lleva el PR**: el maintainer prefiere que la imagen esté
   *adjunta al PR* (*"Evidence pictures should be attached to the PR or put in a
   gist, not hosted on a fork branch"*), pero desde un PR de un fork eso **no
   se puede**:

   - `gh pr edit --attach` responde *"attaching files requires write access to
     the repository"* (el asset se sube al repo **base**, y ahí no hay write);
   - un gist **no muestra la imagen inline**: `gh gist create` rechaza los
     binarios, y con el PNG en base64 dentro de un `README.md` el gist borra el
     `data:` URI y la imagen queda sin `src`.

   Lo que sí funciona (y es lo que hacen los maintainers del repo): una rama
   en el **fork** con los PNG y los links raw en el cuerpo. Si preferís, subilos
   además a un gist (`gh gist create <png> <png> --desc "Evidence for #<N>"`)
   para que el reviewer los tenga de las dos formas, y **decí en el PR que no
   se pueden adjuntar desde un fork** (así el maintainer puede adjuntarlos si
   lo prefiere).

(El tool MCP `screenshot` acepta `path` para dejar el PNG ahí; o
`solidcraft-cli snapshot <script.json> --out <ruta-absoluta>` para el camino
headless. `mkdir -p /home/user/.local/share/solidcraft-loop/evidence` primero si
la carpeta no existe.)

7. Devolvé **las rutas absolutas** de los PNG, la **rama de la evidencia** (en
   el fork) y la **URL del gist** si lo subiste. NO commitees los PNG en la rama
   del fix y NO uses `gh pr edit --attach` (responde *"attaching files requires
   write access to the repository"*).

## Por qué una rama de evidencia y no un attach

La forma ideal de adjuntar una imagen a un PR es `gh pr edit --attach`: sube
el asset a GitHub y deja la imagen **inline**. Desde un PR de un fork eso **no
se puede** (el asset va al repo base, donde el fork no tiene write) y un gist
no renderiza el PNG inline. Lo que queda, y es lo que hacen los maintainers del
repo, es una rama del **fork** (`evidence/<N>-<slug>`) con los PNG y los links
raw en el cuerpo.

**Los PNG nunca van commiteados en la rama del fix**: van en la rama de
evidencia, del fork, y la publica el supervisor al final de la vuelta. Vos no
commiteás nada.

## Reuse the pictures you already have

Before capturing, look at `~/.local/share/solidcraft-loop/evidence/`: if
`<N>-before.png` and `<N>-after.png` are there and the fix has not changed since
they were taken, **return those paths** (`reused: yes`) instead of capturing
again: capturing costs ~35 min of LTO build, and #5302 was captured 4 times
(7a5cdaaf, 8fc9ab8c, d67548d2, 6a4938c7) when the last 3 showed the same
behaviour.

Two commands decide it:

- `date -r ~/.local/share/solidcraft-loop/evidence/<N>-after.png +%s` → when the
  picture was taken.
- `git log -1 --format=%at HEAD` → the **author** date of the fix: a rebase keeps
  it (the committer date changes), so a rebased branch does not invalidate the
  pictures.

Report the sha you captured from in the contract (`sha capturado: <sha>`), so the
orchestrator can tell a rebase from a new fix.

## Reglas

- La captura la hacés **vos**. Nunca le pidas evidencia a un humano.
- Las capturas tienen **dos versiones**: `<nombre>.png` (1600×1000, la que se
  publica en el PR) y `<nombre>.webp` (1024 px, la que debés leer). **Leé
  SIEMPRE el `.webp`**: pesa un 88 % menos y cuesta un 19 % menos tokens de
  contexto que el PNG. El PNG es sólo para publicar. **No releas la misma
  captura**: cada imagen leída se queda en el contexto del modelo y se paga
  siempre.
- Los PNG **nunca** van commiteados al PR del fix: van en la rama `evidence/<N>-<slug>`
  del fork, que publica el supervisor.
- Nada de datos privados en las capturas.

## Contrato de salida (≤15 líneas)

```
antes: <ruta>
después: <ruta>
sha capturado: <sha>
reused: sí | no
adjuntos: <rutas de los PNG, separadas por coma>
```

Si no hay evidencia visual que mostrar, devolvé `antes: n/a`, `después: n/a` y el
motivo en una línea.
