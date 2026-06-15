# board-kit

A portable **filesystem project board** for AI-first repos. Columns are directories,
status transitions are commits, and every active ticket gets its own git worktree — so
multiple agents can pick up, work, and complete tickets with no external tracker.

## The idea

- **Tickets are markdown files** with YAML frontmatter (`id`, `title`, `depends_on`,
  `estimate`, …).
- **Columns are directories** — `todo/` → `in-progress/` → `in-review/` → `done/`, plus
  `blocked/`. Moving a ticket is a `git mv` committed on the integration branch.
- **One worktree+branch per active ticket**, so agents work in isolation.
- **Multi-agent-safe** — claiming a ticket is a single atomic commit; the push to the
  remote is the serialization point (first push wins). Works locally with no remote too.

Intentionally low-tech: if it outgrows a directory of markdown files, migrate to a real
issue tracker rather than bolting automation onto this.

## What's in the kit

| Source | Installs into a target repo as | Role |
|---|---|---|
| `board/` | `.board/` | the `board` CLI, the [reference spec](board/README.md), the ticket template |
| `skill/SKILL.md` | `.claude/skills/<project>-board/` | the agent operating manual |
| `agents/*.md` | `.claude/agents/` | `ticket-implementer` + `ticket-reviewer` subagents |
| `commands/clear-board.md` | `.claude/commands/` | the `/clear-board` orchestrator |

## Quick start

From the root of your target repo, on a clean integration branch:

```bash
cp -R /path/to/board-kit/board ./.board
chmod +x .board/bin/board .board/bin/_lib.sh
.board/bin/board init          # scaffolds the columns + ID allocator
.board/bin/board doctor        # → "board: clean"
```

That stands up the board itself. To also install the agent skill and the autonomous
orchestration layer, follow the full guide in **[INSTALL.md](INSTALL.md)**.

```bash
.board/bin/board create --title "Set up CI" --estimate S --yes
.board/bin/board next          # list claimable tickets
.board/bin/board claim T-001 --agent me --yes
```

## Autonomous orchestration

With the orchestration layer installed, an agent can run **`/clear-board`** to clear the
todo column hands-off: for each claimable ticket it claims → delegates to the
`ticket-implementer` subagent → reviews via the `ticket-reviewer` subagent → fix-loops →
merges → moves the ticket to `done/`. Two modes:

- **PR mode** (default) — pushes a branch, opens a PR, merges with `gh`. Needs the `gh`
  CLI authenticated and a GitHub remote.
- **Local mode** (`/clear-board local`) — commits, reviews, and merges entirely on your
  machine with `git merge --no-ff`. No PR, no remote required.

## How the pieces fit

- **[`board/bin/board`](board/bin/board)** — the CLI is the executable source of truth for
  the protocol; always use it for board mutations.
- **[`skill/SKILL.md`](skill/SKILL.md)** — what an agent loads to *do the work* (CLI cheat
  sheet, the easy-to-break rules, end-to-end flow, race recovery).
- **[`board/README.md`](board/README.md)** — the reference spec: frontmatter schema,
  transitions table, manual fallback.

## Requirements

- `git` with `git worktree` support (any modern git).
- `yq` v4+ (`brew install yq` / `apt install yq`) — the CLI checks for it.
- *(orchestration PR mode only)* the `gh` CLI authenticated + a GitHub remote. Local mode
  needs neither.

## Limits

- Doesn't scale past ~2–3 concurrent agents — coordination cost rises fast.
- Single-host: the worktree protocol assumes all agents share one filesystem.
- `done/` grows unbounded; archive by milestone when it gets noisy.
