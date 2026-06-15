# Board kit — install / stand up from scratch

A portable copy of the filesystem project board: a `board` CLI, a ticket
template, a reference README, and the agent-facing skill. Drop it into any git
repo to get a multi-agent ticket board where columns are directories and
transitions are commits.

This file is the standup guide. An agent can follow it top to bottom.

## What's in the kit

```
board-kit/
  INSTALL.md            ← you are here
  board/                ← copy this into the target repo as .board/
    README.md           reference spec (schema, transitions, manual fallback)
    _template.md        ticket template
    bin/board           the CLI
    bin/_lib.sh         CLI helpers
  skill/
    SKILL.md            ← copy into .claude/skills/<project>-board/
  agents/               ← copy into .claude/agents/ (copy AS-IS — do NOT rename; names are cross-referenced)
    ticket-implementer.md   Sonnet subagent: implements a ticket in its worktree, opens a PR (or commits locally)
    ticket-reviewer.md      Opus subagent: spec-adherence pass + /code-review
  commands/
    clear-board.md      ← copy into .claude/commands/ — the /clear-board orchestrator
```

The `agents/` + `commands/` files are an optional **autonomous orchestration layer**: a
`/clear-board` command that an orchestrating agent runs to clear the todo column on its own,
delegating to the two subagents. They install like the rest of the kit (below) and work in
two modes — PR-based or fully local (see [Autonomous orchestration](#autonomous-orchestration-clear-board)).

## Prerequisites

- A git repository, with the integration branch checked out (default `main`;
  for `master`/`trunk` set `BOARD_MAIN_BRANCH` — see the `BOARD_MAIN_BRANCH` step).
- `yq` v4+ (`brew install yq` / `apt install yq`). The CLI checks for this.
- `git worktree` support (any modern git).
- *(orchestration layer, PR mode only)* the `gh` CLI authenticated (`gh auth status`) and a
  GitHub remote — the implementer opens PRs, the reviewer reads them, the orchestrator merges
  them. **Local mode needs neither** `gh` nor a remote. The base board (CLI + skill) never
  needs `gh`.

## Steps

Run from the **root of the target repo**, on the integration branch, with a clean
working tree. Replace `<project>` with a short repo name (used only to name the
skill).

```bash
# 1. Copy the board into place.
cp -R /path/to/board-kit/board ./.board
chmod +x .board/bin/board .board/bin/_lib.sh

# 2. Scaffold the empty columns + ID allocator.
.board/bin/board init
#   creates todo/ in-progress/ in-review/ blocked/ done/ (each with .gitkeep)
#   and writes .board/.next-id = 1

# 3. Install the skill so agents auto-load the workflow.
mkdir -p .claude/skills/<project>-board
cp /path/to/board-kit/skill/SKILL.md .claude/skills/<project>-board/SKILL.md
#   then edit that file: set `name: <project>-board` in the frontmatter.

# 4. Install the orchestration subagents. Copy AS-IS — do NOT rename:
#   /clear-board and the skill reference them by exact name.
mkdir -p .claude/agents
cp /path/to/board-kit/agents/ticket-implementer.md .claude/agents/
cp /path/to/board-kit/agents/ticket-reviewer.md   .claude/agents/

# 5. Install the /clear-board orchestrator command.
mkdir -p .claude/commands
cp /path/to/board-kit/commands/clear-board.md .claude/commands/

# 6. Commit the scaffold.
git add .board .claude/skills/<project>-board .claude/agents .claude/commands
git commit -m "Add project board (.board/), skill, and orchestration layer"

# 7. (Only if your integration branch isn't `main`) make the override sticky.
#   The CLI reads BOARD_MAIN_BRANCH. Either export it in your shell profile,
#   or wrap the CLI. Quick check it's set right:
#   BOARD_MAIN_BRANCH=master .board/bin/board doctor
```

That's it. Verify:

```bash
.board/bin/board doctor      # → "board: clean"
.board/bin/board status      # → all columns at 0
```

## First ticket

```bash
.board/bin/board create --title "Set up CI" --estimate S --yes
.board/bin/board next        # → lists T-001
.board/bin/board claim T-001 --agent <model>@$(hostname -s) --yes
#   → creates ../<repo>-worktrees/T-001-set-up-ci on branch T-001-set-up-ci
```

From here, agents follow the skill (`.claude/skills/<project>-board/SKILL.md`):
work in the worktree, push a PR, review (spec then quality), then
`board transition T-001 in-review` and eventually `… done`.

## Point your agents at the board

Add a short note to the repo's `CLAUDE.md` (or equivalent) so agents discover the
board without being told each time. Something like:

> This repo uses a filesystem project board at `.board/`. Before starting work,
> read the `<project>-board` skill, run `.board/bin/board next`, and follow the
> claim protocol. Never edit `.board/` by hand.

## Autonomous orchestration (`/clear-board`)

With the orchestration layer installed (steps 4–5), an orchestrating agent can run
**`/clear-board`** to clear the todo column with no human input. For each claimable ticket
(in dependency order) it: claims it → delegates to the `ticket-implementer` subagent →
delegates to the `ticket-reviewer` subagent → drives a fix loop (max 3 rounds) → merges →
moves the ticket to `done/`. Pass a single ticket (`/clear-board T-001`) to process just one.

It runs in two modes:

- **PR mode** (default) — the implementer pushes its branch and opens a PR; the reviewer
  posts `/code-review` comments to the PR; the orchestrator merges with `gh pr merge --squash`.
  Requires the `gh` CLI authenticated and a GitHub remote.
- **Local mode** (`/clear-board local`) — everything stays on this machine: the implementer
  commits to the branch (no push/PR), the reviewer reads the local diff and returns code
  findings inline, and the orchestrator merges with `git merge --no-ff` (which lets the board's
  `done` transition auto-clean the worktree and branch). No `gh`, no remote required.

`commands/clear-board.md` is the source of truth for the loop. As with any agent run, the
human should still exercise the app afterward — runtime/visual correctness isn't auto-verified.

## Customizing

- **Integration branch.** Set `BOARD_MAIN_BRANCH` (default `main`).
- **Repo root.** Auto-detected by walking up from the scripts; override with
  `BOARD_REPO_ROOT` if you symlink or relocate things.
- **Worktree location.** Derived as `../<repo-basename>-worktrees`. To change it,
  edit `WORKTREE_ROOT` in `.board/bin/_lib.sh`.
- **Spec source-of-truth docs.** The template and README refer to "your spec /
  design docs" generically — point ticket Context sections at whatever you use
  (PRD, design docs, an issue tracker export).
- **Two-pass review.** The skill's spec pass uses the `ticket-reviewer` subagent
  installed in step 4. If you skip the orchestration layer, it falls back to
  self-review — the skill handles both.

## Do I need the README, or just the skill?

Both, but they do different jobs and barely overlap:

- **The skill is the operating manual** — it's what an agent loads to *do the
  work*: the CLI cheat sheet, the easy-to-break rules, the end-to-end flow, race
  recovery. Copy it into every repo.
- **The README is the reference spec** — the frontmatter schema, the transitions
  table, design rationale, and the manual fallback for when a script fails. The
  skill points to it (`Manual git fallback`) rather than duplicating it.
- **The CLI scripts are the real source of truth for behavior.** They encode the
  protocol executably, which is why both docs can stay short.

You *can* go skill-only by folding the schema + transitions table into the skill
(or a `reference.md` beside it) and dropping the README — but the README is small,
costs nothing to ship, and is the thing you read when the scripts can't help. Keep
it unless you have a reason not to.
