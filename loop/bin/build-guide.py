#!/usr/bin/env python3
"""Render the SolidCraft visual guide from markdown into the HTML shell.

The guide is a visual document: the CSS, the SVG diagrams and the interactive
bits live in ``docs/guide/shell.html`` (the shell); the prose lives in
``docs/guide/<lang>.md`` (markdown).  This script renders the markdown of one
language into the shell and writes the resulting HTML.

Usage::

    python3 bin/build-guide.py                        # both languages
    python3 bin/build-guide.py --lang en              # only English
    python3 bin/build-guide.py --lang es --out FILE   # one file, anywhere
    python3 bin/build-guide.py --check                # do not write, just diff

Rules of the game:

* The output is deterministic: the same inputs always produce the same bytes.
* A markdown mistake never fails the build: whatever is not understood is left
  as plain text.
* The script always exits 0, and it never touches a file whose source is
  missing.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SHELL_PATH = REPO_ROOT / "docs" / "guide" / "shell.html"
MARKDOWN_PATHS = {
    "en": REPO_ROOT / "docs" / "guide" / "en.md",
    "es": REPO_ROOT / "docs" / "guide" / "es.md",
}
OUTPUT_PATHS = {
    "en": REPO_ROOT / "docs" / "index.html",
    "es": REPO_ROOT / "docs" / "index.es.html",
}
LANGUAGES = ("en", "es")
PLACEHOLDER = "{{CONTENT}}"

# ---------------------------------------------------------------------------
# The chrome of the guide: the strings of the shell that are not the body.
#
# The shell holds the English chrome.  The Spanish build swaps these strings
# for their translation, so the Spanish page keeps its own title, its own
# navigation and its own guided tour.  Everything that the body carries (the
# prose, the diagrams, the tables) comes from the markdown, not from here.
# ---------------------------------------------------------------------------

CHROME = {
    "en": {},
    "es": {
        "replace": [
            (
                '<html lang="en" data-theme="dark">',
                '<html lang="es" data-theme="dark">',
            ),
            (
                "<title>SolidCraft's agent loop — visual guide</title>",
                '<title>El loop de agentes de SolidCraft — guía visual</title>',
            ),
            (
                '<meta name="description" content="A visual, plain-language guide to the logic, flow and rules of the SolidCraft agent loop: orchestrator, triage, claim, implement, evidence, review, gate, publish and the state machine.">',
                '<meta name="description" content="Guía visual y en lenguaje llano de la lógica, el flujo y las reglas del loop de agentes de SolidCraft: orquestador, triage, claim, implement, evidence, review, gate, publish y la máquina de estados.">',
            ),
            (
                "  <h1>SolidCraft's agent loop <span>· visual guide</span></h1>",
                '  <h1>El loop de agentes de SolidCraft <span>· guía visual</span></h1>',
            ),
            (
                '  <button id="theme-toggle" title="Switch light/dark theme" aria-label="Toggle theme">🌙 Dark</button>',
                '  <button id="theme-toggle" title="Cambiar tema claro/oscuro" aria-label="Cambiar tema">🌙 Oscuro</button>',
            ),
            (
                '<nav class="toc" aria-label="Contents">',
                '<nav class="toc" aria-label="Índice">',
            ),
            (
                '  <p class="toc-title">Contents</p>',
                '  <p class="toc-title">Contenido</p>',
            ),
            (
                '  /* --- theme ----------------------------------------------------------- */',
                '  /* --- tema ------------------------------------------------------------ */',
            ),
            (
                '  /* --- guided walkthrough of the state machine --------------------------- */',
                '  /* --- recorrido guiado de la máquina de estados ------------------------ */',
            ),
            (
                '    // the nodes already visited stay green',
                '    // los nodos ya recorridos quedan en verde',
            ),
            (
                '    toggle.textContent = t === "dark" ? "🌙 Dark" : "☀️ Light";',
                '    toggle.textContent = t === "dark" ? "🌙 Oscuro" : "☀️ Claro";',
            ),
            (
                '    playBtn.textContent = "▶ Play the turn";',
                '    playBtn.textContent = "▶ Reproducir la vuelta";',
            ),
            (
                '    playBtn.textContent = "⏸ Pause";',
                '    playBtn.textContent = "⏸ Pausar";',
            ),
            (
                '    textBox.innerHTML = \'<div class="t">Ready to start</div><div class="d">The walkthrough shows the 9 phases with what really happens in each one: which worker acts, what the supervisor writes, and which condition has to be met to move on.</div>\';',
                '    textBox.innerHTML = \'<div class="t">Listo para empezar</div><div class="d">El recorrido muestra las 9 fases con lo que realmente pasa en cada una: qué worker actúa, qué escribe el supervisor y qué condición hay que cumplir para avanzar.</div>\';',
            ),
            (
                '    if (/\\/$/.test(p)) return p + "index.es.html";',
                '    if (/\\/$/.test(p)) return p + "index.html";',
            ),
            (
                '</body>',
                '</body>\n</html>',
            ),
        ],
        "nav": {
            'idea': 'La idea en 30 segundos',
            'medidas': 'Dónde se va el tiempo de verdad',
            'arquitectura': 'Cómo está armado',
            'poderes': 'Quién manda de verdad',
            'estados': 'La máquina de estados',
            'agentes': 'Los 8 agentes, uno por uno',
            'vuelta': 'Una vuelta real, paso a paso',
            'funnel': 'El filtro de los issues',
            'gate': 'El gate de CI, en detalle',
            'invariantes': 'Las reglas indoblegables',
            'permisos': 'Los sandboxes',
            'cuotas': 'Cuotas, modos y presupuestos',
            'nunca': 'Lo que el loop nunca hace',
            'glosario': 'Glosario y rutas',
            'slots': 'El plan multi-issue (slots)',
            'ensayo': 'El banco de ensayo seco',
        },
        "steps": '  var STEPS = [\n    {\n      id: "sm-idle",\n      t: "idle — nada en curso",\n      d: "El supervisor calculó el modo (normal o maintenance), comprobó las precondiciones y lanzó la vuelta. El orquestador lee <code>state.json</code> y ve que no hay nada a medias: empieza por el <strong>triage</strong>."\n    },\n    {\n      id: "sm-selected",\n      t: "selected — el issue está elegido",\n      d: "<code>sc-triage</code> devolvió <em>tomar</em>: es reproducible en ~15 minutos, no hay PR abierto y nadie lo marcó como duplicado. Todavía no existe un PR: el issue es sólo una promesa."\n    },\n    {\n      id: "sm-claimed",\n      t: "claimed — el PR draft existe",\n      d: "<code>sc-claim</code> creó la rama <code>fix/issue-N-slug</code> desde <code>origin/main</code>, dejó el commit vacío <code>claim: #N</code>, pusheó al <em>fork</em> y abrió el PR en draft. La rama vive en el worktree del issue, <code>$HOME/solidcraft-wt/issue-N</code>, fuera del directorio del loop."\n    },\n    {\n      id: "sm-implemented",\n      t: "implemented — el código está commiteado",\n      d: "<code>sc-implement</code> escribió el test primero, vio fallar por la razón correcta, escribió el fix y commiteó en la rama. <strong>Importante:</strong> el veredicto de cualquier revisión anterior queda obsoleto y <code>review</code> vuelve a <code>\\"\\"</code>."\n    },\n    {\n      id: "sm-gating",\n      t: "gating — la CI corre (89-116 min)",\n      d: "<code>sc-review</code> aprobó el diff <strong>declarando el sha que revisó</strong> y el orquestador lanzó el gate con <code>start-gate.sh</code>, atado al SHA de la rama y en su propio worktree. Si ya hay un gate vivo en la máquina, éste queda <strong>en cola</strong> en <code>gates/&lt;slot&gt;/request</code>. La vuelta <strong>se va antes</strong>: el gate no es parte de ella."\n    },\n    {\n      id: "sm-gating",\n      t: "gating — todavía no terminó",\n      d: "El orquestador lee <code>gate.verdict</code>: el supervisor ya calculó el veredicto antes de esta vuelta y lo dejó escrito, así que no hace falta gastarse una llamada de modelo preguntándole algo que el script ya sabe. Dice <code>PENDIENTE</code>: la CI sigue corriendo. <strong>Y no se sale con las manos vacías</strong>: la espera se aprovecha para triagear el próximo issue en paralelo, dejando el resultado en el <code>summary</code> del delta para que el supervisor lo escriba en la bitácora. Así el triage sale del camino crítico."\n    },\n    {\n      id: "sm-gated",\n      t: "gated — la CI dio verde",\n      d: "El veredicto es <code>VERDE</code> (el log terminó con <code>EXIT=0</code> o los únicos fallos son los de la baseline). <strong>El modelo no decide esto</strong>: lo mueve el supervisor, y sólo si el SHA del gate es el head del PR."\n    },\n    {\n      id: "sm-published",\n      t: "published — el PR está listo",\n      d: "<code>sc-publish</code> pusheó al fork, escribió el cuerpo con <code>Fixes #N.</code>, sacó el PR de draft y comentó el issue. Antes de dejar que la fase sea <code>published</code>, el supervisor comprueba que el veredicto de la revisión sea del commit que se está publicando. La fase es terminal y cuenta para la cuota del día."\n    },\n    {\n      id: "sm-idle",\n      t: "published → idle — la vuelta siguiente",\n      d: "La vuelta terminó. El estado queda en disco y, dos minutos después, el temporizador dispara la vuelta siguiente. Si los PRs abiertos sin mergear llegan a 40, el loop entra en modo <strong>maintenance</strong> y deja de abrir issues."\n    }\n  ];',
    },
}# ---------------------------------------------------------------------------
# Small text helpers
# ---------------------------------------------------------------------------

RE_ENTITY = re.compile(
    r"&(?:#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|[A-Za-z][A-Za-z0-9]{1,9});"
)
RE_LINK = re.compile(r"\[([^\]]*)\]\(\s*([^)\s]*)(?:\s+\"[^\"]*\")?\s*\)")
RE_TAG = re.compile(r"</?[A-Za-z][^>]*>")
RE_TAG_NAME = re.compile(r"</?([A-Za-z][A-Za-z0-9-]*)")
RE_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
RE_H2 = re.compile(r"^##\s+(.*)$")
RE_SECTION = re.compile(
    r"^(?:(?P<num>\d{1,3})\s+)?(?P<title>.*?)\s*\{#(?P<id>[A-Za-z0-9_-]+)\}\s*$"
)
RE_NUMBERED_TITLE = re.compile(r"^(\d{1,3})\s+(.*)$")
RE_FENCE = re.compile(r"^(```+|~~~+)\s*([A-Za-z0-9_+.-]*)\s*$")
RE_UL = re.compile(r"^([-*+])\s+(.*)$")
RE_OL = re.compile(r"^(\d{1,9})[.)]\s+(.*)$")
RE_HR = re.compile(r"^(?:-{3,}|\*{3,}|_{3,})\s*$")
RE_HTML_OPEN = re.compile(r"^</?([A-Za-z][A-Za-z0-9-]*)\b")
RE_HTML_COMMENT = re.compile(r"^<!--")

# Tags whose content is code: it is copied, never markdown.
OPAQUE_INLINE_TAGS = frozenset({"code", "kbd", "samp", "pre"})

# Tags whose content is code or a diagram: they are copied as they are.
VERBATIM_TAGS = frozenset({"svg", "pre", "script", "style", "textarea", "math"})
# Tags that carry prose: their content is prose, not a block of its own.
INLINE_TAGS = frozenset(
    {
        "p",
        "li",
        "td",
        "th",
        "figcaption",
        "caption",
        "dt",
        "summary",
        "span",
        "code",
        "em",
        "strong",
        "b",
        "i",
        "a",
        "button",
        "label",
        "small",
        "abbr",
        "mark",
        "sub",
        "sup",
        "u",
        "time",
    }
)
# Tags that, at the beginning of a line, are prose and not a block of HTML.
INLINE_PROSE_TAGS = frozenset(
    {
        "code",
        "em",
        "strong",
        "b",
        "i",
        "span",
        "a",
        "br",
        "small",
        "abbr",
        "mark",
        "sub",
        "sup",
        "u",
        "time",
        "label",
        "q",
        "cite",
        "kbd",
        "var",
        "samp",
        "img",
        "wbr",
    }
)


def escape_code(text: str) -> str:
    """Escape the text that goes inside a ``<code>`` or a ``<pre>``."""
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def escape_attr(text: str) -> str:
    """Escape the text that goes inside an HTML attribute."""
    return escape_code(text).replace('"', "&quot;")


def indent_of(line: str) -> int:
    """Return the number of leading spaces of a line."""
    return len(line) - len(line.lstrip(" "))


def pad(indent: int) -> str:
    """Return the indentation prefix of a generated line."""
    return " " * indent


def strip_common_indent(line: str, base: int) -> str:
    """Remove up to ``base`` leading spaces, keeping the extra ones."""
    stripped = line.lstrip(" ")
    removed = len(line) - len(stripped)
    if removed >= base:
        return stripped
    return " " * (base - removed) + stripped


def shift_lines(lines: list[str], shift: int) -> list[str]:
    """Move a block of lines ``shift`` columns to the right."""
    if shift == 0:
        return list(lines)
    moved = []
    for line in lines:
        if not line.strip():
            moved.append("")
        else:
            moved.append(pad(max(0, indent_of(line) + shift)) + line.lstrip(" "))
    return moved


# ---------------------------------------------------------------------------
# Inline markdown
# ---------------------------------------------------------------------------


def render_inline(text: str) -> str:
    """Render the inline markdown of a line of prose.

    Supported: ``**bold**``, ``*italic*``, ```code```, ``[text](url)``, and the
    raw HTML that the guide already uses (``<code>``, ``<em>``, ``<br>``, ...).
    Everything else is left alone.
    """
    out: list[str] = []
    index = 0
    size = len(text)
    while index < size:
        char = text[index]
        if char == "\\" and index + 1 < size and text[index + 1] in "\\`*[]_":
            out.append(text[index + 1])
            index += 2
            continue
        if char == "`":
            end = text.find("`", index + 1)
            if end != -1:
                out.append("<code>" + escape_code(text[index + 1 : end]) + "</code>")
                index = end + 1
                continue
        if text.startswith("<!--", index):
            end = text.find("-->", index)
            if end != -1:
                out.append(text[index : end + 3])
                index = end + 3
                continue
        if char == "<":
            end = text.find(">", index + 1)
            if end != -1 and RE_TAG.match(text[index : end + 1]):
                tag = RE_TAG_NAME.match(text[index : end + 1])
                if tag and tag.group(1).lower() in OPAQUE_INLINE_TAGS:
                    # The content of a <code> is code: it is copied as it is.
                    closing = "</%s>" % tag.group(1)
                    close = text.lower().find(closing.lower(), end)
                    if close != -1:
                        out.append(text[index : close + len(closing)])
                        index = close + len(closing)
                        continue
                out.append(text[index : end + 1])
                index = end + 1
                continue
            out.append("&lt;")
            index += 1
            continue
        if char == "&":
            entity = RE_ENTITY.match(text, index)
            if entity:
                out.append(entity.group(0))
                index = entity.end()
                continue
            out.append("&amp;")
            index += 1
            continue
        if text.startswith("**", index):
            end = text.find("**", index + 2)
            if end != -1:
                out.append("<strong>" + render_inline(text[index + 2 : end]) + "</strong>")
                index = end + 2
                continue
            # There is no closing "**": the stars are plain text.
            out.append("**")
            index += 2
            continue
        if char == "*":
            end = text.find("*", index + 1)
            if end != -1 and end > index + 1:
                out.append("<em>" + render_inline(text[index + 1 : end]) + "</em>")
                index = end + 1
                continue
        if char == "[":
            link = RE_LINK.match(text, index)
            if link:
                out.append(
                    '<a href="'
                    + escape_attr(link.group(2))
                    + '">'
                    + render_inline(link.group(1))
                    + "</a>"
                )
                index = link.end()
                continue
        out.append(char)
        index += 1
    return "".join(out)


# ---------------------------------------------------------------------------
# Block markdown
# ---------------------------------------------------------------------------


def count_tag(line: str, tag: str) -> tuple[int, int]:
    """Count the opening and the closing tags of ``tag`` in one line."""
    escaped = re.escape(tag)
    opens = len(re.findall(r"<%s(?=[\s/>])" % escaped, line))
    self_closing = len(re.findall(r"<%s(?=[\s/>])[^<>]*/>" % escaped, line))
    closes = len(re.findall(r"</%s(?=[\s>])" % escaped, line))
    return opens - self_closing, closes


def find_block_end(lines: list[str], start: int, tag: str) -> int:
    """Return the index of the line that closes the tag opened at ``start``."""
    depth = 0
    for index in range(start, len(lines)):
        opens, closes = count_tag(lines[index], tag)
        depth += opens - closes
        if depth <= 0:
            return index
    return len(lines) - 1


def split_row(line: str) -> list[str]:
    """Split a table row into its cells."""
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|") and not text.endswith("\\|"):
        text = text[:-1]
    cells: list[str] = []
    current: list[str] = []
    index = 0
    while index < len(text):
        char = text[index]
        if char == "\\" and index + 1 < len(text) and text[index + 1] == "|":
            current.append("|")
            index += 2
            continue
        if char == "|":
            cells.append("".join(current).strip())
            current = []
            index += 1
            continue
        current.append(char)
        index += 1
    cells.append("".join(current).strip())
    return cells


def is_table_separator(line: str) -> bool:
    """Say whether a line is the separator of a table."""
    if "|" not in line:
        return False
    cells = split_row(line)
    if not cells:
        return False
    return all(re.match(r"^:?-+:?$", cell.strip()) for cell in cells)


def starts_block(lines: list[str], index: int) -> bool:
    """Say whether the line at ``index`` opens a new block."""
    stripped = lines[index].strip()
    if not stripped:
        return True
    if RE_HEADING.match(stripped) or RE_FENCE.match(stripped) or RE_HR.match(stripped):
        return True
    if stripped.startswith(">"):
        return True
    if RE_UL.match(stripped) or RE_OL.match(stripped):
        return True
    if RE_HTML_COMMENT.match(stripped):
        return True
    match = RE_HTML_OPEN.match(stripped)
    if match and match.group(1).lower() not in INLINE_PROSE_TAGS:
        return True
    return False


def render_paragraph(
    lines: list[str], index: int, indent: int, inline_paragraphs: bool, state: dict
) -> tuple[list[str], int]:
    """Render a paragraph: the lines until a blank line or the next block."""
    body: list[str] = []
    while index < len(lines):
        if not lines[index].strip():
            break
        if body and starts_block(lines, index):
            break
        body.append(lines[index])
        index += 1
    base = indent_of(body[0]) if body else 0
    rendered = [render_inline(strip_common_indent(line, base)) for line in body]
    if inline_paragraphs:
        # Inside a raw HTML block the prose stays prose: the block already is
        # the paragraph, and a <p> inside it would break the layout.
        return ([pad(indent) + line if line else "" for line in rendered], index)
    klass = "lede" if state.get("lede") else "body"
    state["lede"] = False
    out = [pad(indent) + '<p class="%s">' % klass]
    out.extend(pad(indent + 2) + line if line else "" for line in rendered)
    out.append(pad(indent) + "</p>")
    return (out, index)


def render_fence(lines: list[str], index: int, indent: int) -> tuple[list[str], int]:
    """Render a fenced code block as ``<pre><code>``."""
    marker = RE_FENCE.match(lines[index].strip()).group(1)
    body: list[str] = []
    cursor = index + 1
    while cursor < len(lines) and not lines[cursor].strip().startswith(marker):
        body.append(lines[cursor])
        cursor += 1
    base = indent_of(body[0]) if body else 0
    content = [escape_code(strip_common_indent(line, base)) for line in body]
    if not content:
        return ([pad(indent) + "<pre><code></code></pre>"], cursor + 1)
    out = [pad(indent) + "<pre><code>" + content[0]]
    out.extend(content[1:-1])
    out.append(content[-1] + "</code></pre>")
    return (out, cursor + 1)


def render_heading(level: int, title: str, indent: int) -> list[str]:
    """Render a heading."""
    return [pad(indent) + "<h%d>%s</h%d>" % (level, render_inline(title), level)]


def render_html(
    lines: list[str], index: int, indent: int, inline_paragraphs: bool, state: dict
) -> tuple[list[str], int]:
    """Render a raw HTML block.

    The HTML is copied as it is and the markdown inside it is rendered: the
    layout stays HTML, the prose becomes markdown.
    """
    first = lines[index].strip()
    if RE_HTML_COMMENT.match(first):
        end = index
        while end < len(lines) and "-->" not in lines[end]:
            end += 1
        end = min(end + 1, len(lines))
        block = lines[index:end]
        return (shift_lines(block, indent - indent_of(block[0])), end)
    tag = RE_HTML_OPEN.match(first).group(1).lower()
    end = find_block_end(lines, index, tag)
    block = lines[index : end + 1]
    shift = indent - indent_of(block[0])
    if tag in VERBATIM_TAGS:
        # A diagram or a piece of code: it is copied, word for word.
        return (shift_lines(block, shift), end + 1)
    if len(block) == 1:
        return ([shift_lines([block[0]], shift)[0]], end + 1)
    open_line = shift_lines([block[0]], shift)[0]
    close_line = shift_lines([block[-1]], shift)[0]
    inner = block[1:-1]
    if tag in INLINE_TAGS:
        rendered = [render_inline(line) for line in shift_lines(inner, shift)]
        return ([open_line] + rendered + [close_line], end + 1)
    # The content of a block keeps the indentation it has in the markdown: a
    # raw tag stays where it is, a markdown block nests one level deeper.
    inner_indent = indent + 2
    first_inner = next((line for line in inner if line.strip()), None)
    if first_inner is not None:
        stripped = first_inner.strip()
        match = RE_HTML_OPEN.match(stripped)
        raw = bool(match) and match.group(1).lower() not in INLINE_PROSE_TAGS
        if raw:
            inner_indent = max(
                indent, indent + indent_of(first_inner) - indent_of(block[0])
            )
    chunks = render_blocks(inner, inner_indent, True, state)
    out = [open_line]
    out.extend(join_chunks(chunks))
    out.append(close_line)
    return (out, end + 1)


def render_quote(
    lines: list[str], index: int, indent: int, inline_paragraphs: bool, state: dict
) -> tuple[list[str], int]:
    """Render a blockquote."""
    body: list[str] = []
    cursor = index
    while cursor < len(lines) and lines[cursor].strip().startswith(">"):
        text = lines[cursor].strip()[1:]
        if text.startswith(" "):
            text = text[1:]
        body.append(text)
        cursor += 1
    chunks = render_blocks(body, indent + 2, inline_paragraphs, state)
    out = [pad(indent) + "<blockquote>"]
    out.extend(join_chunks(chunks))
    out.append(pad(indent) + "</blockquote>")
    return (out, cursor)


def render_list(
    lines: list[str], index: int, indent: int, inline_paragraphs: bool, state: dict
) -> tuple[list[str], int]:
    """Render a list: every item becomes a ``<li>``."""
    base = indent_of(lines[index])
    ordered = bool(RE_OL.match(lines[index].strip()))
    items: list[tuple[str, list[str]]] = []
    cursor = index
    while cursor < len(lines):
        raw = lines[cursor]
        stripped = raw.strip()
        if not stripped:
            look = cursor
            while look < len(lines) and not lines[look].strip():
                look += 1
            if (
                look < len(lines)
                and indent_of(lines[look]) == base
                and (RE_UL.match(lines[look].strip()) or RE_OL.match(lines[look].strip()))
            ):
                cursor = look
                continue
            break
        match = RE_UL.match(stripped) or RE_OL.match(stripped)
        if not match:
            break
        item_indent = indent_of(raw)
        if item_indent < base:
            break
        if item_indent > base:
            # A deeper item: it belongs to the item above it.
            nested, cursor = render_list(lines, cursor, indent + 4, inline_paragraphs, state)
            if items:
                items[-1][1].extend(nested)
            continue
        if bool(RE_OL.match(stripped)) != ordered:
            # Another kind of list: this one is over.
            break
        text = match.group(2).strip()
        cursor += 1
        while (
            cursor < len(lines)
            and lines[cursor].strip()
            and not RE_UL.match(lines[cursor].strip())
            and not RE_OL.match(lines[cursor].strip())
            and indent_of(lines[cursor]) > base
        ):
            text += " " + lines[cursor].strip()
            cursor += 1
        items.append((text, []))
    out = [pad(indent) + ("<ol>" if ordered else "<ul>")]
    for text, nested in items:
        out.append(pad(indent + 2) + "<li>" + render_inline(text))
        if nested:
            out.extend(nested)
            out.append(pad(indent + 2) + "</li>")
        else:
            out[-1] += "</li>"
    out.append(pad(indent) + ("</ol>" if ordered else "</ul>"))
    return (out, cursor)


def render_table(lines: list[str], index: int, indent: int) -> tuple[list[str], int]:
    """Render a pipe table."""
    header = split_row(lines[index])
    rows: list[list[str]] = []
    cursor = index + 2
    while cursor < len(lines) and lines[cursor].strip() and "|" in lines[cursor]:
        rows.append(split_row(lines[cursor]))
        cursor += 1
    out = [
        pad(indent) + '<div class="table-wrap">',
        pad(indent) + "<table>",
        pad(indent + 2) + "<thead>",
        pad(indent + 4)
        + "<tr>"
        + "".join("<th>%s</th>" % render_inline(cell) for cell in header)
        + "</tr>",
        pad(indent + 2) + "</thead>",
        pad(indent + 2) + "<tbody>",
    ]
    for row in rows:
        out.append(
            pad(indent + 4)
            + "<tr>"
            + "".join("<td>%s</td>" % render_inline(cell) for cell in row)
            + "</tr>"
        )
    out.append(pad(indent + 2) + "</tbody>")
    out.append(pad(indent) + "</table>")
    out.append(pad(indent) + "</div>")
    return (out, cursor)


class Chunk:
    """A block of HTML and the rule that joins it with the next one."""

    __slots__ = ("lines", "glue", "sticky")

    def __init__(self, lines: list[str], sticky: bool = False) -> None:
        self.lines = lines
        # A sticky block is glued to the one that follows it (a heading).
        self.sticky = sticky
        self.glue = sticky


def render_blocks(
    lines: list[str], indent: int, inline_paragraphs: bool, state: dict
) -> list[Chunk]:
    """Render a list of markdown lines into a list of blocks.

    The blank lines of the markdown are the blank lines of the HTML: a block
    that follows a blank line in the source is separated from the one before
    it.  A heading is always glued to the block that follows it, the way the
    guide is written today.
    """
    chunks: list[Chunk] = []
    index = 0
    blank_before = False
    while index < len(lines):
        stripped = lines[index].strip()
        if not stripped:
            blank_before = True
            index += 1
            continue
        block: list[str]
        glue = False
        start = index
        fence = RE_FENCE.match(stripped)
        if fence:
            block, index = render_fence(lines, index, indent)
        else:
            heading = RE_HEADING.match(stripped)
            if heading:
                level = len(heading.group(1))
                block = render_heading(level, heading.group(2).strip(), indent)
                glue = True
                index += 1
            else:
                match = RE_HTML_OPEN.match(stripped)
                if RE_HTML_COMMENT.match(stripped) or match:
                    if match and match.group(1).lower() in INLINE_PROSE_TAGS:
                        # A tag that belongs to the prose: not a block of HTML.
                        block, index = render_paragraph(
                            lines, index, indent, inline_paragraphs, state
                        )
                    else:
                        block, index = render_html(
                            lines, index, indent, inline_paragraphs, state
                        )
                elif stripped.startswith(">"):
                    block, index = render_quote(
                        lines, index, indent, inline_paragraphs, state
                    )
                elif RE_UL.match(stripped) or RE_OL.match(stripped):
                    block, index = render_list(
                        lines, index, indent, inline_paragraphs, state
                    )
                elif (
                    "|" in stripped
                    and index + 1 < len(lines)
                    and is_table_separator(lines[index + 1])
                ):
                    block, index = render_table(lines, index, indent)
                elif RE_HR.match(stripped):
                    block = [pad(indent) + "<hr>"]
                    index += 1
                else:
                    block, index = render_paragraph(
                        lines, index, indent, inline_paragraphs, state
                    )
        chunks.append(Chunk(block, glue))
        if len(chunks) > 1:
            # The blank line that separates two blocks is the one that comes
            # before the second one.
            previous = chunks[-2]
            previous.glue = previous.sticky or not blank_before
        if index > start and not lines[index - 1].strip():
            # The block ate the blank line that came before the next one.
            blank_before = True
        else:
            blank_before = False
    return chunks


def join_chunks(chunks: list[Chunk]) -> list[str]:
    """Join the blocks of a document, keeping the blank lines of the source."""
    out: list[str] = []
    for position, chunk in enumerate(chunks):
        if position and not chunks[position - 1].glue:
            out.append("")
        out.extend(chunk.lines)
    return out


def is_comment_chunk(chunk: Chunk) -> bool:
    """Say whether a block is only an HTML comment."""
    return bool(chunk.lines) and all(
        not line.strip() or RE_HTML_COMMENT.match(line.strip()) for line in chunk.lines
    )


def slugify(title: str) -> str:
    """Build the anchor of a section that does not carry one."""
    slug = re.sub(r"[^A-Za-z0-9]+", "-", title.strip().lower()).strip("-")
    return slug or "seccion"


def parse_section_heading(line: str) -> tuple[str, str, str]:
    """Return the number, the title and the anchor of an ``h2``.

    The anchor is mandatory (``## 03 A title {#anchor}``); when it is missing
    one is built from the title, so the guide never breaks.
    """
    body = RE_H2.match(line.strip()).group(1)
    match = RE_SECTION.match(body)
    if match:
        return (match.group("num") or "", match.group("title").strip(), match.group("id"))
    number = ""
    title = body.strip()
    numbered = RE_NUMBERED_TITLE.match(title)
    if numbered:
        number = numbered.group(1)
        title = numbered.group(2).strip()
    return (number, title, slugify(title))


def render_section(head: str, body: list[str]) -> tuple[list[str], list[str]]:
    """Render one section: the ``h2`` and everything that belongs to it.

    It returns the section and the comments that close it: a comment at the
    end of a section belongs between two sections, not inside one of them.
    """
    number, title, anchor = parse_section_heading(head)
    if number:
        heading = '<span class="num">%s</span>%s' % (number, render_inline(title))
    else:
        heading = render_inline(title)
    out = ['<section id="%s">' % escape_attr(anchor), pad(2) + "<h2>" + heading + "</h2>"]
    state = {"lede": True}
    chunks = render_blocks(body, 2, False, state)
    trailing: list[str] = []
    while chunks and is_comment_chunk(chunks[-1]):
        trailing = [line.lstrip(" ") for line in chunks.pop().lines] + trailing
    out.extend(join_chunks(chunks))
    out.append("</section>")
    return (out, trailing)


def render_document(text: str) -> str:
    """Render the markdown of one language into the body of the guide."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    chunks: list[Chunk] = []
    pending: list[str] = []
    index = 0
    while index < len(lines):
        if RE_H2.match(lines[index].strip()):
            if pending:
                chunks.extend(render_blocks(pending, 0, False, {"lede": False}))
                pending = []
            body: list[str] = []
            cursor = index + 1
            while cursor < len(lines) and not RE_H2.match(lines[cursor].strip()):
                body.append(lines[cursor])
                cursor += 1
            section, trailing = render_section(lines[index], body)
            chunks.append(Chunk(section, False))
            if trailing:
                chunks.append(Chunk(trailing, True))
            index = cursor
            continue
        pending.append(lines[index])
        index += 1
    if pending:
        chunks.extend(render_blocks(pending, 0, False, {"lede": False}))
    return "\n".join(join_chunks(chunks))


# ---------------------------------------------------------------------------
# The chrome of the shell
# ---------------------------------------------------------------------------

RE_NAV_ITEM = re.compile(r'(<li><a href="#(?P<id>[^"]+)">)(?P<label>[^<]*)(</a></li>)')


def apply_chrome(html: str, lang: str, warn) -> str:
    """Translate the chrome of the shell for one language."""
    chrome = CHROME.get(lang) or {}
    for old, new in chrome.get("replace", []):
        if old not in html:
            warn("el shell ya no tiene este trozo: %s" % old[:60])
            continue
        html = html.replace(old, new, 1)
    labels = chrome.get("nav") or {}

    def relabel(match: re.Match) -> str:
        label = labels.get(match.group("id"))
        if label is None:
            return match.group(0)
        return match.group(1) + label + match.group(4)

    if labels:
        html = RE_NAV_ITEM.sub(relabel, html)
    steps = chrome.get("steps")
    if steps:
        start = html.find("  var STEPS = [")
        end = html.find("\n  ];", start)
        if start == -1 or end == -1:
            warn("el shell ya no tiene el recorrido guiado")
        else:
            html = html[:start] + steps + html[end + len("\n  ];") :]
    return html


# ---------------------------------------------------------------------------
# The build
# ---------------------------------------------------------------------------


def write_atomic(path: Path, text: str) -> None:
    """Write a file atomically: a temporary file, then a rename."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(
        prefix=path.name + ".", suffix=".tmp", dir=str(path.parent)
    )
    try:
        with os.fdopen(handle, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o644)
        os.replace(temporary, path)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise


def build_language(
    lang: str, shell: str, markdown_path: Path, warn
) -> str | None:
    """Render one language, or return ``None`` when its markdown is missing."""
    if not markdown_path.exists():
        warn("falta el markdown de %s (%s): no se toca ningún fichero" % (lang, markdown_path))
        return None
    try:
        text = markdown_path.read_text(encoding="utf-8")
    except OSError as exc:
        warn("no se puede leer %s: %s" % (markdown_path, exc))
        return None
    content = render_document(text)
    html = apply_chrome(shell, lang, warn)
    if PLACEHOLDER not in html:
        warn("la plantilla no tiene %s: no se escribe nada" % PLACEHOLDER)
        return None
    return html.replace(PLACEHOLDER, content)


class _UsageError(Exception):
    """A wrong command line."""


class _Parser(argparse.ArgumentParser):
    """An argument parser that never exits with a non-zero status."""

    def error(self, message: str) -> None:  # pragma: no cover - argparse hook
        raise _UsageError(message)


def build_parser() -> argparse.ArgumentParser:
    """Build the command line parser."""
    parser = _Parser(
        prog="build-guide.py",
        description=(
            "Render the markdown of the guide into the HTML shell and write "
            "docs/index.html (English) and docs/index.es.html (Spanish)."
        ),
        epilog=(
            "The build is deterministic and never fails: a markdown mistake is "
            "left as plain text and the script always exits 0."
        ),
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--lang",
        choices=list(LANGUAGES),
        help="build only this language (by default both are built)",
    )
    parser.add_argument(
        "--out",
        metavar="FILE",
        help="write to FILE instead of the default path ('-' means stdout)",
    )
    parser.add_argument(
        "--shell",
        metavar="FILE",
        help="use another shell template (by default docs/guide/shell.html)",
    )
    parser.add_argument(
        "--md",
        metavar="FILE",
        help="use another markdown source (only with --lang)",
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="do not write anything: say whether the file would change",
    )
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="only report the problems",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    """Build the guide. It always returns 0."""
    parser = build_parser()
    try:
        args = parser.parse_args(argv)
    except _UsageError as exc:
        sys.stderr.write("Error: %s\n" % exc)
        sys.stderr.write(parser.format_usage())
        return 0

    def warn(message: str) -> None:
        sys.stderr.write("aviso: %s\n" % message)

    def info(message: str) -> None:
        if not args.quiet:
            sys.stdout.write("%s\n" % message)

    if args.out and not args.lang:
        sys.stderr.write("Error: --out necesita --lang (en o es)\n")
        return 0
    if args.md and not args.lang:
        sys.stderr.write("Error: --md necesita --lang (en o es)\n")
        return 0

    shell_path = Path(args.shell) if args.shell else SHELL_PATH
    if not shell_path.exists():
        sys.stderr.write("Error: no se encuentra la plantilla %s\n" % shell_path)
        return 0
    try:
        shell = shell_path.read_text(encoding="utf-8")
    except OSError as exc:
        sys.stderr.write("Error: no se puede leer la plantilla %s: %s\n" % (shell_path, exc))
        return 0

    languages = [args.lang] if args.lang else list(LANGUAGES)
    for lang in languages:
        markdown_path = Path(args.md) if args.md else MARKDOWN_PATHS[lang]
        html = build_language(lang, shell, markdown_path, warn)
        if html is None:
            continue
        if args.out:
            destination = Path(args.out)
        else:
            destination = OUTPUT_PATHS[lang]
        if str(destination) == "-":
            sys.stdout.write(html)
            continue
        if args.check:
            current = ""
            if destination.exists():
                try:
                    current = destination.read_text(encoding="utf-8")
                except OSError:
                    current = ""
            if current == html:
                info("%s está al día (%d bytes)" % (destination, len(html.encode("utf-8"))))
            else:
                info("%s cambiaría (%d bytes ahora, %d bytes después)"
                     % (destination, len(current.encode("utf-8")), len(html.encode("utf-8"))))
            continue
        try:
            write_atomic(destination, html)
        except OSError as exc:
            warn("no se puede escribir %s: %s" % (destination, exc))
            continue
        info("escribo %s (%d bytes)" % (destination, len(html.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
