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
```

## Prerequisites

- A git repository, with the integration branch checked out (default `main`;
  for `master`/`trunk` set `BOARD_MAIN_BRANCH` — see step 5).
- `yq` v4+ (`brew install yq` / `apt install yq`). The CLI checks for this.
- `git worktree` support (any modern git).

## Steps

Run from the **root of the target repo**, on the integration branch, with a clean
working tree. Replace `<project>` with a short repo name (used only to name the
skill, e.g. `civis`).

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

# 4. Commit the scaffold.
git add .board .claude/skills/<project>-board
git commit -m "Add project board (.board/) and skill"

# 5. (Only if your integration branch isn't `main`) make the override sticky.
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

## Customizing

- **Integration branch.** Set `BOARD_MAIN_BRANCH` (default `main`).
- **Repo root.** Auto-detected by walking up from the scripts; override with
  `BOARD_REPO_ROOT` if you symlink or relocate things.
- **Worktree location.** Derived as `../<repo-basename>-worktrees`. To change it,
  edit `WORKTREE_ROOT` in `.board/bin/_lib.sh`.
- **Spec source-of-truth docs.** The template and README refer to "your spec /
  design docs" generically — point ticket Context sections at whatever you use
  (PRD, design docs, an issue tracker export).
- **Two-pass review.** The skill's spec pass uses a `ticket-reviewer` subagent if
  one exists; otherwise it falls back to self-review. Define that subagent if you
  want a dedicated, ticket-aware reviewer.

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
