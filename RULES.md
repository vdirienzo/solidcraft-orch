# Reglas del orquestador (2026-11-21)

Las reglas de SolidCraft viven en upstream, no acá: `AGENTS.md`, `CONTRIBUTING.md` y
`.agents/skills/*/SKILL.md` en `origin/main` (`git -C "$SOLIDCRAFT_REPO" show origin/main:<ruta>`).
Para un PR: `solidcraft-full-stop` (de punta a punta), `solidcraft-file-pr`,
`solidcraft-babysit-pr` (su `scripts/pr-wait`), `solidcraft-takeover`, `solidcraft-repro-first` y
`solidcraft-kernel-rules`.

`bash bin/rules-sync.sh` hace `git fetch origin` y dice si upstream movió alguna. Exit 1 con la
lista: la wave para, se lee `bash bin/rules-snapshot.sh --diff`, se revisan este archivo y
`prompts/`, y recién entonces `bash bin/rules-snapshot.sh --update`.

## Solo de este orquestador

1. Push solo al fork (`fork` = vdirienzo). `origin` es upstream: se lee, no se empuja.
2. El claim va primero: commit vacío en `fix-N`, draft `TÍTULO (#N)` con `Fixes #N`, y
   enseguida `bash bin/claim-verify.sh N <pr>` (0 nuestro, 1 perdido, 2 no se sabe).
   Gana el PR abierto de número más bajo; si perdimos, se cierra el nuestro.
3. Inglés en todo lo público: títulos, bodies, commits y comentarios.
4. Sin comentarios de estado, y nunca pedir `approved-for-ci` (lo pone el maintainer).
5. Esta caja (12 cores, 15 GB) no compila el kernel: se vetan los issues de `crates/kernel` y
   `solidcore/`. Upstream los acepta; el veto es nuestro, por la máquina.
6. Un build pesado a la vez: `bash bin/slot-lock.sh --heavy --take --wait 3600`, con `nice`.
