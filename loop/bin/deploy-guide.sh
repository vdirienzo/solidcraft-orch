#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# deploy-guide.sh - regenerate the visual guide and publish it to Vercel.
#
# The guide is a visual document, but its TEXT lives in markdown
# (docs/guide/en.md and docs/guide/es.md): the agent edits the markdown and
# this script renders it into the HTML and publishes it. The HTML is never
# hand-edited: it is a build artifact.
#
#   deploy-guide.sh [commit message]
#
# WHAT IT DOES:
#   1. runs bin/build-guide.py, which writes docs/index.html (English) and
#      docs/index.es.html (Spanish) from the markdown and the template;
#   2. copies both into the directory of the Vercel project (the deploy root);
#   3. commits them there (that directory is a git repository: the history of
#      the guide) and pushes the deployment with `vercel --prod`.
#
# WHAT IT NEVER DOES: touch the loop's state, the prompts or the runtime.
# A failure here never breaks a turn: this script is run by a human.
# ---------------------------------------------------------------------------
set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LOOP_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
# The guide lives in the REPOSITORY, not in the runtime copy: the runtime copy
# has its own docs/index.html (the dashboard of the loop, which is a different
# document published in a different project). GUIDE_ROOT points at the
# repository, where docs/guide/ and bin/build-guide.py live.
GUIDE_ROOT="${GUIDE_ROOT:-$HOME/solidcraft-loop}"
SITE_DIR="${SITE_DIR:-$HOME/solidc-site}"
MESSAGE="${1:-}"

export PATH="$HOME/.local/bin:$HOME/.local/node/bin:$PATH"

if [ ! -f "$GUIDE_ROOT/bin/build-guide.py" ]; then
  echo "deploy-guide: falta el generador ($GUIDE_ROOT/bin/build-guide.py)" >&2
  exit 1
fi

echo "deploy-guide: generando la guia..."
if ! python3 "$GUIDE_ROOT/bin/build-guide.py"; then
  echo "deploy-guide: el generador fallo: no se publico nada" >&2
  exit 1
fi

for f in index.html index.es.html; do
  if [ ! -s "$GUIDE_ROOT/docs/$f" ]; then
    echo "deploy-guide: falta o esta vacio docs/$f: no se publico nada" >&2
    exit 1
  fi
done

if [ ! -d "$SITE_DIR" ]; then
  echo "deploy-guide: el directorio del proyecto de Vercel no existe ($SITE_DIR)" >&2
  exit 1
fi

cp "$GUIDE_ROOT/docs/index.html" "$SITE_DIR/index.html"
cp "$GUIDE_ROOT/docs/index.es.html" "$SITE_DIR/index.es.html"

if [ -d "$SITE_DIR/.git" ]; then
  if [ -z "$MESSAGE" ]; then
    MESSAGE="Update the guide: the text of the guide in markdown, rendered"
  fi
  ( cd "$SITE_DIR" && git add -A && git commit -q -m "$MESSAGE" ) \
    && echo "deploy-guide: commit en el repositorio de la guia" \
    || echo "deploy-guide: no hubo cambios que commitear"
fi

echo "deploy-guide: publicando en Vercel..."
if ! ( cd "$SITE_DIR" && vercel --prod --yes ); then
  echo "deploy-guide: vercel fallo: el HTML esta actualizado en $GUIDE_ROOT/docs" >&2
  exit 1
fi

echo "deploy-guide: publicado."
