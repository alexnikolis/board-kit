---
description: Autonomously clear the board's todo column — implement, review, and merge each ticket.
argument-hint: "[T-NNN] [local]  (optional ticket; add 'local' for no-PR local mode)"
model: opus
---

You are the **orchestrator** for the project's `.board/` board. Your job is to clear the
`.board/` todo column **autonomously, with no human input**: for each claimable ticket,
claim it, delegate implementation and review to sub-agents, drive a fix loop until it
passes, then merge the work and move the ticket to `done/`. Follow the board's
claim/transition protocol (see `.board/README.md` or the project's board skill).

Argument: `$ARGUMENTS` — may contain a ticket ID and/or a mode token, in any order.
- If it names a ticket (e.g. `T-001`), process **only that ticket**, then stop.
- If it omits a ticket, **loop until the board is clear** (no more claimable tickets).
- If it contains the token `local`, run in **local mode**; otherwise run in **PR mode** (default).

## Modes

- **PR mode** (default) — the implementer pushes its branch and opens a PR; the reviewer posts
  `/code-review` comments to the PR; you merge with `gh pr merge --squash`. Requires the `gh` CLI
  authenticated and a GitHub remote.
- **Local mode** (`local`) — everything stays on this machine. The implementer commits to the
  branch in its worktree (no push, no PR); the reviewer reads the local diff and returns code
  findings inline; you merge the branch into the integration branch with `git merge --no-ff`. No
  `gh`, no remote required. Pass the mode into every sub-agent's prompt.

## Your role vs. the sub-agents

- **You** run every `git`, `gh`, merge, and `.board/bin/board` command — always from the
  **main checkout on the integration branch** (usually `main`; the board honors
  `BOARD_MAIN_BRANCH`). Board mutations happen *only* here, never from a worktree.
- You delegate via the Agent tool to two custom agents — **tell each one the mode**:
  - `ticket-implementer` — writes the code in the ticket's worktree. PR mode: pushes + opens the PR. Local mode: commits only. Re-used in fix-loop mode.
  - `ticket-reviewer` — spec-adherence review + `/code-review`. PR mode: posts `--comment` to the PR. Local mode: returns code findings inline. Returns ranked findings + a verdict.
- **Do not** pass `isolation: worktree` to the Agent tool — the board's `board claim`
  already creates the worktree. Tell each implementer the absolute worktree path to work in.

## Pre-flight (once, before any ticket)

Run and confirm each; abort with a clear message if any fails.

Both modes:
- `.board/bin/board doctor` — clean.
- `.board/bin/board status` and `.board/bin/board next` — see what's claimable.

PR mode only:
- `gh auth status` — authenticated (needed for PR create + merge for the whole run).
- `git pull --ff-only` (from the main checkout) — integration branch up to date.
- `git push --dry-run` (or a no-op push check) — origin reachable / pushable.

Local mode: skip the `gh` and push checks. Run `git pull --ff-only` only if an `origin` remote
exists; a repo with no remote is fine.

## Per-ticket loop

Process tickets in **dependency order** — `.board/bin/board next` lists only tickets whose
`depends_on` are all in `done/`. For each ticket `T-NNN`:

1. **Sync + claim.** `git pull --ff-only` (skip if local mode with no `origin`), then
   `.board/bin/board claim T-NNN --agent orchestrator --yes`. This creates the branch
   `T-NNN-slug` and its worktree. Read the ticket's `worktree:` frontmatter (or
   `board show T-NNN`) to get the exact worktree path and branch.
   - If claim exits non-zero with `claim_lost`, run `board next` and pick another ticket (do not retry the same one).

2. **Implement.** Spawn `ticket-implementer` (subagent_type: `ticket-implementer`) with:
   the ticket ID, the **mode**, the absolute worktree path, the branch name, and the **full
   ticket body** (from `board show T-NNN`). It implements, self-checks, and commits.
   - **PR mode:** it pushes and opens a PR — capture the **PR number** from its summary
     (or `gh pr list --head T-NNN-slug`).
   - **Local mode:** it stops after committing — capture the **branch + latest commit SHA**.

3. **Review.** Spawn `ticket-reviewer` (subagent_type: `ticket-reviewer`) with the ticket
   file path (`.board/in-progress/T-NNN-slug.md`) and the **mode**, plus — in PR mode — the
   **PR number**, or — in local mode — the **worktree path + branch**. It runs the
   spec-adherence pass + `/code-review` and returns ranked findings + a **verdict** (in local
   mode the code findings come back inline in its report).

4. **Fix loop (max 3 iterations).** If the verdict is not `ready-for-merge` (or there are
   gating code findings): spawn `ticket-implementer` again in **fix-loop mode** — pass the
   reviewer's findings.
   - **PR mode:** also tell it to read `gh pr view <PR> --comments`; it resolves and pushes to the same branch.
   - **Local mode:** paste the reviewer's inline code findings into its prompt (there are no PR comments); it resolves and commits to the same branch.
   Then re-run the reviewer (step 3). Repeat until `ready-for-merge` or 3 iterations elapse.
   - If still not ready after 3 iterations: `.board/bin/board block T-NNN "<short reason>"`,
     record it for the final report, and move on to the next claimable ticket.

5. **Merge + finish.** On `ready-for-merge`:
   - **Merge into the integration branch (from the main checkout):**
     - **PR mode:** `gh pr merge <PR> --squash --delete-branch`, then `git pull --ff-only` to
       bring the squash commit into the local integration branch.
     - **Local mode:** `git merge --no-ff T-NNN-slug -m "T-NNN: <title>"`. The `--no-ff` merge
       makes the branch count as merged, so the `done` transition below auto-deletes it. (Resolve
       any conflict before continuing.)
   - `.board/bin/board transition T-NNN in-review --yes`.
   - Append an **`## Outcome`** section to the ticket body (the `done` transition requires
     it): note the merge reference (**PR mode:** `PR #NN` + squash commit SHA; **local mode:**
     the merge commit SHA), a one-line of what shipped, and any deviations. (Edit the ticket
     file in the main checkout, then `git add`/`commit` it as part of the transition, per the
     board protocol — or use the board's own transition flow which verifies the Outcome section exists.)
   - `.board/bin/board transition T-NNN done --yes`. This removes the worktree and deletes the merged branch.

6. **Continue** (full-board mode only) until `board next` is empty.

## Parallel window

When `board next` surfaces **more than one** claimable ticket and they touch largely
disjoint areas of the codebase, you may claim them and run their implementers concurrently
(multiple Agent calls in one message, each pointed at its own worktree). **Merge them to the
integration branch sequentially** (re-pulling between merges in PR mode), and resolve any
conflict before claiming a ticket that depends on them. If running concurrently adds risk you
can't manage, fall back to strictly sequential — correctness over speed.

## Final report

When done (or when the single ticket finishes), report:
- Tickets completed (with PR #s in PR mode, or merge commit SHAs in local mode) and the final `board status`.
- Any tickets left in `blocked/` with their reasons.
- Confirm the project's build / checks are clean on the integration branch (per its CLAUDE.md / `.claude/rules`).
- Remind the user to manually exercise the app — runtime/visual correctness is not auto-verified.
