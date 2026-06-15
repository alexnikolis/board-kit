# Project board

A filesystem-based project board. Tickets are markdown files; columns are
directories; status transitions are commits on the integration branch. Day-to-day
work goes through the `board` CLI (`.board/bin/board`) — this README is the
reference spec behind it: the schema, the transition rules, and the manual
fallback for when a script can't help you.

The source of truth for *what* to build lives in your own spec / design docs.
Tickets are the unit of agent-executable work derived from them.

This board is intentionally low-tech. If it outgrows that, migrate to a real
issue tracker rather than bolting automation onto this directory.

## Layout

```
<repo>/                      main checkout, lives on the integration branch
  .board/                    only ever edited here, on that branch
    README.md                this file
    _template.md             copy this to create a new ticket (the CLI does it for you)
    .next-id                 monotonic ID allocator; never hand-edit
    bin/board, bin/_lib.sh   the CLI
    todo/                    ready to be claimed; dependencies may not yet be met
    in-progress/             actively being worked; exactly one agent claimed
    in-review/               work complete, awaiting human sign-off
    blocked/                 cannot proceed; blocked_reason explains why
    done/                    merged and verified; includes an Outcome section

../<repo>-worktrees/         sibling dir, one git worktree per active ticket
  T-014-some-slug/           worktree on branch T-014-some-slug
```

Paths are derived automatically from the repo location — the CLI computes the
worktree root as `../<repo-basename>-worktrees`. Nothing is hardcoded.

## Lifecycle

```
        ┌──────────────────────────────┐
        │                              │
        ▼                              │
     todo  ──claim──►  in-progress  ──►  in-review  ──approve──►  done
                          ▲   │              │
                          │   └── blocked ◄──┘
                          │       │
                          └───────┘ (unblock)
```

Allowed transitions:

- `todo → in-progress` — agent claims (atomic; see [Claim protocol](#claim-protocol)).
- `in-progress → in-review` — agent believes work is complete and verified.
- `in-review → done` — human approves.
- `in-review → in-progress` — changes requested.
- Any column → `blocked` and back — set/clear `blocked_reason`.

Anything else (e.g. `todo → done`) is a bug.

## Frontmatter schema

Every ticket starts with YAML frontmatter. Fields:

| Field | Type | Description |
|---|---|---|
| `id` | string | Stable identifier (`T-001`, `T-002`, …). Matches filename prefix. Never reused, never renumbered. |
| `title` | string | Short imperative summary. Match the H1 in the body. |
| `depends_on` | list of ids | Tickets that must be in `done/` before this one can be claimed. |
| `blocks` | list of ids | Inverse of `depends_on`. Best-effort, kept in sync manually. |
| `estimate` | `S` \| `M` \| `L` | Rough size. `S` ≈ <2h, `M` ≈ half-day, `L` ≈ multi-day — split if larger. |
| `agent` | string or null | The agent currently working it. `null` in `todo/`, `in-review/`, `done/`. |
| `claimed_at` | ISO-8601 string or null | When the ticket entered `in-progress/`. Cleared on move to `in-review/`. |
| `worktree` | string or null | Path to the worktree (e.g. `../<repo>-worktrees/T-NNN-slug`). Set on claim, cleared on done. |
| `blocked_reason` | string or null | One-line reason. Set when in `blocked/`, cleared on unblock. |

## Transitions

All transitions are a `git mv` in the main checkout on the integration branch,
with frontmatter edits in the same commit. The CLI does this; the table is the
spec it implements (and what to follow if you ever go manual).

| Transition | Frontmatter changes | Worktree action |
|---|---|---|
| `todo → in-progress` | set `agent`, `claimed_at`, `worktree` | `git worktree add -b T-NNN-slug ../<repo>-worktrees/T-NNN-slug <branch>` |
| `in-progress → in-review` | clear `claimed_at` (keep `agent`, keep `worktree`) | none — worktree stays |
| `in-review → in-progress` | re-set `claimed_at` | none — reuse worktree |
| `in-review → done` | append **Outcome** section, clear `agent`, `worktree`, `claimed_at` | `git worktree remove …`, `git branch -d …` if merged |
| any → `blocked` | set `blocked_reason` | worktree stays if it existed; otherwise none |
| `blocked → previous` | clear `blocked_reason` | none |

## Claim protocol

Multi-agent safety rests on two rules:

1. **Board mutations only happen in the main checkout, on the integration
   branch.** Never edit `.board/` from a feature worktree — the change won't be
   visible to other agents until merge, defeating the protocol.
2. **Claiming is a single atomic commit** that moves the file and edits its
   frontmatter. The push to the remote is the serialization point; whoever
   pushes first wins, everyone else's push is rejected and they bail (pick
   another ticket — do **not** retry the same one).

`board claim` implements both. The worktree is created only *after* the claim
push succeeds, so a lost race leaves no orphan worktree.

## Worktrees

One in-progress (or in-review) ticket ↔ one branch ↔ one worktree.

- **Why.** A per-ticket worktree isolates each agent's working tree so build
  artifacts and branch switches in one ticket don't disturb another. The shared
  git state still lives in the main checkout; only the working directory and
  `HEAD` are per-ticket.
- **Where.** Under `../<repo>-worktrees/` (sibling to the repo), one subdir per
  active ticket, named after the slug.
- **Lifecycle.** Created at claim; kept through `in-review ↔ in-progress`
  toggles; removed on move to `done/`.
- **Diagnostics.** `git worktree list` shows current state. `git worktree prune`
  clears stale registrations after a directory was deleted out from under git.

## Conventions

- **IDs are monotonic.** Highest existing ID + 1, allocated by `.next-id`. Never
  reuse, never renumber, even if a ticket is deleted.
- **Filenames never change after creation.** Only the parent directory changes.
  This keeps branch names, commit prefixes, and cross-references stable. Format:
  `T-NNN-kebab-case-slug.md`.
- **One ticket per branch.** Branch name = filename without `.md`.
- **Commits reference the ID.** First line starts with `T-NNN: `.
- **Mark done by appending an `## Outcome` section** before moving to `done/`.
  This is what makes `done/` a useful archive instead of dead weight.
- **Cross-doc references live in prose, not frontmatter.** Link spec sections
  from the **Context** body section. Frontmatter is machine-readable fields only.
- **Use the CLI to author and edit tickets.** Never bump `.next-id` or hand-edit
  frontmatter — both produce conflicts `board doctor` will flag.

## Manual fallback

If a script fails for a reason it doesn't cover, the protocol above *is* the spec
— do it by hand, respecting two hard rules:

- All board mutations happen in the main checkout on the integration branch, in a
  single commit per transition.
- Edit frontmatter with `yq` (the scripts use it); don't improvise YAML by hand.
  After any manual edit, run `board doctor`.

## Known limits

- This board doesn't scale past ~2–3 concurrent agents. The push-to-win claim
  race works, but coordination cost rises fast.
- **Single-host assumption.** The worktree protocol assumes all agents share one
  filesystem. Multi-host coordination needs a different mechanism entirely.
- **Validation is best-effort.** `board doctor` catches duplicates, missing
  fields, stale worktrees, and a desynced `.next-id`, but it is not a schema
  validator. Treat recurring pain as a signal to migrate off the filesystem
  rather than to invest in tooling here.
- `done/` grows unbounded. Fine early on; archive by milestone (`done/v1/`, …)
  when it gets noisy.
