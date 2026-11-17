# Brief: corregir los BODIES de 4 PRs abiertos (sin compilar, sin tocar codigo)

Esta tarea NO compila NADA y NO toca codigo. Solo edita el cuerpo de los PRs con `gh pr edit`.
NO abras PRs nuevos. NO hagas push. NO toques origin.

REGLA CRITICA DEL PARSER DEL UPSTREAM (verificada contra scripts/pr-checks/pr-checks.js):
El regex real es /^[ \t]*(?:[-*][ \t]+)?Changes a default:[ \t]*(.*?)[ \t]*$/im
La linea debe quedar FUERA de code fences, sin comentarios HTML y sin backticks inline.
Los 4 bodies ya la tienen bien puesta: NO la toques, NO la muevas, NO la reescribas.

## PR #9843 (issue #7114) - head 9c7f595d
1. La linea 227 dice: `- **The PR stays a draft.** The evidence above is what the maintainer asked for; the branch is`
   Eso es FALSO: el PR NO es draft (isDraft=false). Corregi la frase para que diga la verdad
   (por ejemplo: el PR esta listo para review, no es un draft). Mantené el sentido del resto del parrafo.
2. Las 2 capturas son links SUELTOS a raw.githubusercontent.com, no imagenes embebidas:
     https://raw.githubusercontent.com/vdirienzo/solidcraft/evidence/7114-snap-grid-visible/7114-grid-crossing.png
     https://raw.githubusercontent.com/vdirienzo/solidcraft/evidence/7114-snap-grid-visible/7114-fine-lattice.png
   El check `hasPicture` del upstream (que reconoce `![](...)`, `<img src>` o `user-attachments`)
   devuelve false con links sueltos. Conviertelos en imagenes EMBEBIDAS:
     ![The point lands on the grid crossing](https://raw.githubusercontent.com/.../7114-grid-crossing.png)
     ![The fine lattice is kept when the snap is refused](https://raw.githubusercontent.com/.../7114-fine-lattice.png)
   Mantené el texto alternativo descriptivo. Los dos PNG existen (HTTP 200).
   NO borres los links: dejalos como links, AGREGA la forma embebida.

## PR #11074 (issue #5237) - head 8f35b629
1. La primera linea dice `Fixes #5237`. El issue #5237 pide ademas tips, ejemplos, capturas y
   crowd-sourcing de snippets; el PR solo entrega la tabla de parametros. Eso es un cierre PARCIAL,
   asi que la linea correcta es `Addresses #5237` (no `Fixes`). Cambiala.
2. En el bloque del gate, el `SHA=` citado debe ser el SHA DEL HEAD (8f35b6291e6aa629c61500b2b2af43e929f7a608),
   no uno viejo. Buscalo en el body y corregilo si no coincide.

## PR #11280 (issue #10747) - head 8982f130
1. Hay un fence VACIO roto: las lineas 68-69 son un ``` de apertura y un ``` de cierre sin nada
   adentro, y la linea 71 abre otro fence. Borra el fence vacio (lineas 68-69) para que el bloque
   del gate quede bien formado.
2. El `SHA=fd9b1fbc70f1cf8310927d1b78a2d8d22b528270` de la linea 79 NO es el head del PR.
   El head es 8982f130. Corregi el SHA. Si el numero de fallos del gate tampoco coincide con el
   gate vigente, actualizalo; si no lo podes verificar, NO inventes numeros: poni solo lo que
   puedas verificar con el gate local en
   /home/user/.local/share/solidcraft-loop/gates/10747-inspect/scope.effective.verdict
   (leelo: de ahi salen VERDICT, NEW_FAILURES, PREEXISTING y el SHA).
   Si ese archivo no existe o su SHA no coincide con 8982f130, NO pegues ningun bloque de gate:
   borralo y poni una frase honesta de que el gate vigente se pega al final.
3. Verifica que la linea `Changes a default: no` este presente y fuera de cualquier fence. Si no
   esta, agregala como linea propia (texto exacto: `Changes a default: no`).

## PR #12263 (issue #2216) - head ea7b264c - ESTE ES DRAFT
- Este PR esta en DRAFT y su body tiene `Fixes #2216`. El issue #2216 pedia que el sweep
  aceptara el path de una arista; si el PR cubre SOLO eso, `Fixes` es correcto. NO lo cambies
  sin evidencia. Dejalo como esta. Solo verifica que la linea `Changes a default: no` este
  fuera de los fences (esta bien puesta).
- No toques nada mas de este PR.

## Como editar
Para cada PR:
  gh pr view <N> --repo tangency-labs/solidcraft --json body > /tmp/body-<N>.json
  (extrae el body a un archivo de texto, editá ese archivo)
  gh pr edit <N> --repo tangency-labs/solidcraft --body-file /tmp/body-<N>.md
Despues de cada edicion, verificá:
  gh pr view <N> --repo tangency-labs/solidcraft --json body --jq '.body'
y compará que la unica diferencia sean los cambios que hiciste (diff).

## Entrega
Por PR: que cambiaste, el diff del body (antes/despues de las lineas tocadas), y la confirmacion
de que `Changes a default: no` quedo intacto y fuera de fences.
Si algo no lo pudiste verificar, decilo. No inventes contenido.
