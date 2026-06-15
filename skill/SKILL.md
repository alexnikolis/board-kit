---
name: project-board
description: Pick up, work on, transition, and complete tickets on the filesystem project board (`.board/`). Use this whenever you are about to start work on a board ticket, when the user asks you to "grab a ticket" or "work the next ticket," when transitioning a ticket between columns (todo/in-progress/in-review/blocked/done), or when handling a board-related race or conflict. Triggered by mentions of the board, ticket IDs (`T-NNN`), the `.board/` directory, the `board` CLI, or the worktree-per-ticket workflow.
---

# project-board

<!-- RENAME this skill per repo: change `name:` above and the directory to
     `<project>-board` (e.g. `civis-board`) so the description triggers cleanly. -->

The project board lives at `.board/`. Tickets are markdown files; columns are
subdirectories; transitions are commits on the integration branch. There is a CLI
wrapper at `.board/bin/board` — **always use it for board mutations**. Editing
files in `.board/` by hand bypasses race protection and frontmatter validation.

> If `.board/` doesn't exist yet, stand it up first — see `INSTALL.md` in the
> board kit, or run `.board/bin/board init` once the scripts are in place.

## Cheat sheet

```
.board/bin/board next                                                → list claimable tickets
.board/bin/board create --title "..." [--depends-on T-NNN,...] --yes → mint a new ticket
.board/bin/board update T-NNN --add-dep T-MMM --yes                  → edit frontmatter safely
.board/bin/board claim T-NNN --agent <me> --yes                      → take a ticket (atomic; may exit 2 if lost)
.board/bin/board status                                              → who owns what
.board/bin/board show T-NNN                                          → read a ticket
.board/bin/board transition T-NNN in-review --yes                    → submit for review
.board/bin/board transition T-NNN done --yes                         → mark complete (after appending Outcome)
.board/bin/board block T-NNN "<reason>"                              → can't proceed
.board/bin/board doctor                                              → sanity check
```

Agents should pass `--yes` to any mutating command (`claim`, `transition`,
`block`, `unblock`) — the scripts otherwise prompt for confirmation.

## Rules that are easy to break

- **Run `board *` from the main checkout on the integration branch.** The scripts
  refuse otherwise. Feature work happens in the per-ticket worktree at
  `../<repo>-worktrees/T-NNN-slug/`. (Repos on `master`/`trunk` instead of `main`:
  set `BOARD_MAIN_BRANCH` — see `board help`.)
- **Never edit `.board/` files by hand** for routine transitions. Use `board
  transition`. Hand edits skip the atomic commit and frontmatter rules.
- **Never claim a ticket whose `depends_on` aren't all in `done/`.** `board claim`
  enforces this; bypassing it will break someone else's work.
- **Before `transition … done`, append an `## Outcome` section** to the ticket
  body (PR link, commits, 1–3 sentences on what shipped). The script refuses
  without one.
- **On `claim_lost` (exit 2), don't retry the same ticket.** Run `board next` and
  pick a different one. The first claim won the race.
- **One ticket per branch, branch name = slug.** `board claim` creates
  `T-NNN-slug` automatically. Don't rename branches.
- **Never bump `.board/.next-id` by hand or create tickets without `board
  create`.** The script allocates IDs atomically and rewrites on push-reject;
  manual creation causes ID collisions that `board doctor` will flag but can't
  auto-fix.
- **Link spec / design-doc sections from the Context body, not the frontmatter.**
  Frontmatter is for machine-readable fields only.
- **Before `board transition … in-review`, review the work — spec first, quality
  second** (see below). Verifying intent before polishing keeps quality findings
  from landing on code that's about to change.

### Pre-review (run before moving to `in-review`)

1. **Spec pass — does the diff satisfy the ticket?** Check the change against the
   ticket's acceptance criteria, verification plan, and out-of-scope list.
   - If this repo defines a `ticket-reviewer` subagent, invoke it via the `Agent`
     tool (`subagent_type: 'ticket-reviewer'`), passing the ticket file path and
     PR number. Otherwise do this as a careful self-review, or spawn a fresh
     general-purpose subagent with the ticket file + diff.
   - **Address Blocker / Actionable findings before moving on.** If the work isn't
     actually complete, keep coding — don't transition.
2. **Quality pass — generic code review.** Run `/code-review medium --comment` if
   available (it posts findings to the PR), or your repo's equivalent. Run this
   **only after** the spec pass is clean — findings on incomplete code are
   partially stale. Address real issues in a follow-up commit; leave
   stylistic/debatable notes for the human reviewer.

## End-to-end flow

```
# 1. From the main checkout, on the integration branch:
.board/bin/board next
.board/bin/board claim T-014 --agent <model>@$(hostname -s) --yes
# → creates the worktree at ../<repo>-worktrees/T-014-slug and branch T-014-slug

# 2. Do the work in the worktree:
cd ../<repo>-worktrees/T-014-slug
# … edit, commit, push the feature branch, open a PR …

# 3. Spec pass — confirm the change satisfies the ticket (see Pre-review above).
#    Address Blocker / Actionable findings in a follow-up commit BEFORE step 4.

# 4. Quality pass — once the spec pass is clean:
/code-review medium --comment
# Address real bugs / missed cases. Leave debatable notes for the human reviewer.

# 5. Back in the main checkout, submit for review:
.board/bin/board transition T-014 in-review --yes

# 6. After review + merge, append an Outcome section to the ticket,
#    then mark done (worktree and merged branch are auto-cleaned):
$EDITOR .board/in-review/T-014-*.md   # add `## Outcome`
.board/bin/board transition T-014 done --yes
```

## Race recovery

- **`board claim` exits 2 with `claim_lost`** — another agent claimed the ticket
  between your `board next` and your `board claim`. Your local checkout has
  already been reset; just run `board next` again.
- **`board transition` aborted without `--yes`** — no state changed. Re-run with
  `--yes`.
- **`board doctor` reports issues** — fix them before further mutations. Common
  causes: a missing `## Outcome` on a `done/` ticket added by hand, a stale
  worktree path after a manual `git worktree remove`, a feature branch with no
  matching ticket. Use `git worktree prune` and re-run `doctor`.

## Manual git fallback

If a script fails for a reason this skill doesn't cover, the canonical written
protocol is in `.board/README.md`. Two hard rules when going manual:

- All board mutations happen in the main checkout on the integration branch, in a
  single commit per transition.
- Edit frontmatter with `yq` (the scripts use it); do **not** improvise YAML by
  hand. After any manual edit, run `board doctor`.

## Reference

- `.board/README.md` — full protocol, frontmatter schema, transitions table.
- `.board/_template.md` — the ticket template.
- Your repo's spec / design docs — source of truth for *what* to build (the
  tickets decompose these). Link them from each ticket's Context section.
