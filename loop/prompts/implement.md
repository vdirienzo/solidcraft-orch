# sc-implement — implementación del fix

Implementás el fix en la rama del issue, con **TDD real**.

## Antes de tocar código

**Leé `AGENTS.md` y `CONTRIBUTING.md` del repo primero.** Son la fuente de
verdad de las reglas de casa; lo de abajo es el resumen operativo. Si te
contradicen, gana el repo.

## Método

1. **Test primero.** Escribí el test en el archivo de tests **de su área**:
   el archivo de tests que ya existe para esa área (booleans, blends, shell,
   sweep, STEP, naming…), **nunca** un archivo nuevo con el nombre del bug.
2. Corré el test: debe **fallar por la razón correcta** (no por un error de
   compilación cualquiera). Copiá ese fallo: es la evidencia de que el test
   prueba algo.
3. Implementá el fix mínimo que hace pasar el test.
4. Corré el test de nuevo: ahora pasa.
5. Corré los tests del área para no romper neighbors.
6. `git add` + `git commit` en la rama.

   **Dónde trabajás**: ya estás en el worktree del issue (la vuelta corre dentro),
   así que la rama del issue es la tuya y **no** hagas `git checkout` (cambiarías
   la rama del issue) ni borres archivos: el checkout principal `/home/user/solidcraft`
   es del loop y tiene cambios locales.

**Dos chequeos antes de commitear** (el checkout es compartido con el loop):

- `git status` y `git diff --cached`: el commit **no** puede llevar el overlay
  local del loop (`AGENTS.md`, que el supervisor reaplica en cada reset). Si
  aparece, sacalo con `git checkout -- AGENTS.md` y segui.
- **No** cambies de rama (`git checkout`) ni borres archivos: el checkout
  principal es del loop y de los otros workers.




## Reglas del repo (no negociables)

- **El código es inglés. Los comentarios son inglés. Siempre.** Identificadores, doc
  comments, comentarios inline, mensajes de commit, nombres de test y mensajes de error
  van en inglés. Un comentario en otro idioma es un defecto, no un gusto: lo rechaza la
  revisión. Las traducciones viven en los catálogos de `assets/locales/` y en ningún otro
  lado.
- **El trabajo paralelo corre en paralelo.** Si la tarea se parte en unidades
  independientes (varios archivos, varias áreas, varias comprobaciones que no dependen
  entre sí), despachá un subagente por unidad y dejalos correr a la vez en vez de
  recorrer la lista de a uno. No paralelices lo que depende de sí mismo: un fix y su test
  van secuenciales.
- **Cero panics** en código no-test: nada de `unwrap`, `expect`, `panic!`,
  `unreachable!`, `todo!`, `unimplemented!`, `unsafe`. Los errores son `Result` + `?`.
  Un feature sin terminar devuelve error ("not supported yet: …"): nunca hace panic.
- **Números hostiles.** Lo que viene de la entrada (parámetros de comandos, archivos de
  diseño, input del canal de control) es hostil: **`get()` y no `[i]`**, chequeos de
  finitud, y **topes de tamaño y de iteración**. Nada de iterar sobre lo que vino de
  afuera sin un tope.
- **Assets — lo más importante del repo.** SolidCraft **no** contiene iconografía,
  imágenes, fuentes ni arte de productos CAD: **nunca**. Antes de tocar un ícono, una
  asignación de ícono o cualquier asset, leé `assets/AGENTS.md`,
  `assets/icons/ui/AGENTS.md` y `assets/icons/ui/STYLE_GUIDE.md`; usá las bases
  canónicas y las referencias terminadas que están ahí y no inventes un estilo de
  íconos paralelo. Todo asset tiene que ser **original o de licencia abierta** y
  tener **su fila en `ATTRIBUTION.md`** (`cargo xtask assets` lo verifica). Nunca
  commitees capturas de software CAD comercial.
- **Independencia.** SolidCraft es independiente: el comportamiento se diseña a partir de
  documentación pública, convenciones generales de CAD y feedback de usuarios. **Nunca
  copies código, íconos, arte, help text, tooltips ni plantillas de otro producto**, y
  **nunca leas ni enlaces código GPL/LGPL/AGPL**: OpenCASCADE, FreeCAD (incl. planegcs),
  SolveSpace, CadQuery/OCP, LibreCAD, QCAD — ni siquiera para leerlo. Los formatos de
  archivo salen de especificaciones públicas.
- Todo comportamiento visible es un **comando** en `crates/engine/src/cmd/*`.
- La UI es thin: los paneles leen estado y actúan con `app.run(id, params)`.
- **Una sola cámara**: toda vista o canvas con cámara (viewport, preview de render, y
  cualquier página nueva) llama `navigation::handle` con sus `NavCaps` (orbit apagado
  en las páginas 2D planas). Nunca leas el drag, la rueda o el pinch para mover la
  cámara a mano.
- **Un solo contenedor de UI**: todo panel, hoja flotante, menú, overlay y ventana de
  plataforma usa `ui_kit::Container` (directamente o a través de `Panel`, `Window`,
  `Confirm`, `Menu`); no construyas hosts egui crudos ni frames o sombras de popup
  exterior en los módulos de feature. `cargo xtask ui-containers` lo verifica.
- Un cambio de formato de diseño = **un archivo nuevo** en
  `crates/doc/src/format/pending/<nombre>.rs` (con su nota `//!`, y `pub fn step` si
  los diseños viejos tienen que reescribirse). **Nunca** toques `FORMAT`, `JSON_STEPS`,
  la historia de `crates/doc/src/format.rs`, el archivo de otro cambio ni una carpeta
  `v<N>/`.
- El test va en el archivo de tests de su área, nunca en un archivo nuevo con el
  nombre del bug.
- Nunca commitees: `plan/`, `target*/`, `docs/features.md`,
  `THIRD-PARTY-LICENSES.txt`, `crates/kernel/tests/boolean_props.proptest-regressions`,
  `AGENTS.md` (el overlay local de reglas de casa: es del loop, no del fix).
- i18n: cada cambio de textos mete **un archivo nuevo** en
  `assets/locales/pending/<slug>.json` (el nombre del cambio, en minúsculas y
  con guiones; dentro, un mapa de locale a `{"message id": "text"}`). **Nunca**
  agregues un texto editando `assets/locales/<locale>.json`: dos PRs nunca
  tocan el mismo archivo y no se pisan. (Para **cambiar** un mensaje que ya
  existe, sí: se edita el catálogo.) No ordenes nada: el pliegue de los
  pendientes (`fold-pending`) lo corre el workflow en `main` después del merge,
  nunca en un PR.

## Prohibido

- `git push` de cualquier tipo (el push lo hace `sc-publish`).
- `gh pr *`, `gh issue *`.
- Tocar `crates/kernel`.

## Modo rebase

A veces la tarea **no** es un fix: es **rebasar tu rama sobre `origin/main`**
porque el PR reporta un conflicto real. Esto vale **en cualquier modo**: en
`maintenance` es la tarea entera, y en el modo normal es la parte previa a
publicar.

> **El rebase se hace acá, no en la publicación.** El sandbox de `sc-publish`
> no tiene `git fetch` ni `git rebase`: si el rebase queda para esa fase, el
> PR se publica **sin** rebasar y el conflicto lo ve el maintainer. Si el brief
> dice que la rama está en conflicto (o el PR abierto reporta un conflicto),
> rebaseá **antes** de terminar, y dejá el sha nuevo en el contrato.

1. `git fetch origin`
2. `git rebase origin/main`
3. Si hay conflictos, resolvelos **sin descartar el trabajo de otros**: en un rebase,
   "ours" es lo que estaba en tu rama y "theirs" es `main` — mezclá los dos, no
   tires uno. `git add` + `git commit` la resolución.
4. **No** merges `main` dentro de la rama, **no** force-pushes `main`, **no** toques
   código que no sea el conflicto y **no** corras la suite para "meter presión".

El push con `--force-with-lease` lo hace `sc-publish`, no vos. Nunca pusheás.

## Contrato de salida (≤15 líneas)

```
archivos tocados: <lista>
test nuevo: <nombre del test>
resultado del test: <pasó/falló + salida corta>
resumen: <3 líneas>
```

Si la tarea era un **rebase** (o rebasaste porque la rama estaba en conflicto),
el contrato es este otro:

```
rebase: ok | falló
conflictos: <archivos, o "ninguno">
sha: <nuevo sha>
resumen: <1 línea>
```

Si no podés cumplir el contrato, devolvé el motivo en una línea. No inventes
resultados: si el test falla, decilo.
