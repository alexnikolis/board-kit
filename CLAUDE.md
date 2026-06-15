# CLAUDE.md

## What this is

`board-kit` is a **portable template**, not a running app. Its files are copied into *other*
repos to stand up a filesystem project board (columns are directories, transitions are commits).
No build, no tests — just bash (`board/bin/`) and markdown. The CLI needs `yq` v4+ and
`git worktree`. `INSTALL.md` is the standup guide.

## Layout → where each piece installs in a target repo

| Source here | Installs to |
|---|---|
| `board/` (CLI, `README.md` spec, ticket `_template.md`) | `.board/` |
| `skill/SKILL.md` | `.claude/skills/<project>-board/` |
| `agents/{ticket-implementer,ticket-reviewer}.md` | `.claude/agents/` |
| `commands/clear-board.md` | `.claude/commands/` |

## Source of truth for behavior

`board/bin/board` + `board/bin/_lib.sh` implement the protocol executably — 11 subcommands:
`init, next, create, update, claim, transition, block, unblock, status, show, doctor`. The docs
*describe* the protocol; the scripts *are* it. **Change behavior in the scripts and keep the
docs in sync** in the same change.

## Doc roles — keep them non-overlapping (a design value)

- `INSTALL.md` — standup guide.
- `board/README.md` — reference spec (frontmatter schema, transitions table, manual fallback).
- `skill/SKILL.md` — the agent operating manual (loaded to *do* the work).
- `agents/*` + `commands/clear-board.md` — the optional autonomous orchestration layer.

Don't duplicate content across these; cross-reference instead.

## Hard constraints when editing

- The **skill** is renamed `<project>-board` per install, but the **agent/command names**
  (`ticket-implementer`, `ticket-reviewer`, `clear-board`) are generic and cross-referenced by
  **exact name** (the orchestrator spawns subagents by name; the skill invokes `ticket-reviewer`).
  Never rename them or the wiring breaks.
- The orchestration layer has **two modes**: PR (default; needs `gh` + a remote) and local
  (`/clear-board local`; no remote, no PR). Every PR/`gh`/push action must stay mode-gated.
- The CLI is **remote-optional** — every `git push` is guarded by `git remote get-url origin`.
  Preserve that when touching the scripts so local mode keeps working with no `origin`.
- Low-tech by design: if the board outgrows the filesystem, migrate to a real tracker rather
  than adding automation here.

## Before committing

`bash -n board/bin/board board/bin/_lib.sh` to syntax-check the scripts.
