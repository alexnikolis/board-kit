#!/usr/bin/env bash
# install.sh — stand up the board kit in a target repo.
#
# Copies the payload (board/ → .board/, skill/agents/command → .claude/…) into the
# current git repo, renames the skill to <project>-board, runs `board init`, and stages
# the result. It never commits — review and commit yourself.
#
# Run from inside the target repo, on its integration branch, with a clean tree:
#
#   curl -fsSL https://raw.githubusercontent.com/alexnikolis/board-kit/main/install.sh | bash -s -- --project <name>
#   # or, from a clone/extract of board-kit:
#   /path/to/board-kit/install.sh --project <name>
#
# Flags:
#   --project <name>       skill name becomes <name>-board (default: this repo's dir name)
#   --main-branch <branch> integration branch to install on (default: $BOARD_MAIN_BRANCH or main)
#   --base-only            install the board + skill only; skip the orchestration agents/command
#   --update               refresh skill/agents/command in place; leave .board/ data untouched
#   -h, --help             show this help
#
# Env:
#   BOARD_KIT_REPO  git URL to clone when run via curl (default: the public board-kit repo)

set -euo pipefail

REPO_DEFAULT="https://github.com/alexnikolis/board-kit"
BOARD_KIT_REPO="${BOARD_KIT_REPO:-$REPO_DEFAULT}"

die()  { echo "install: $*" >&2; exit 1; }
info() { echo "install: $*" >&2; }

usage() {
  cat >&2 <<'EOF'
install.sh — stand up the board kit in a target repo.

Usage (run from inside the target repo, on its integration branch, clean tree):
  curl -fsSL https://raw.githubusercontent.com/alexnikolis/board-kit/main/install.sh | bash -s -- --project <name>
  /path/to/board-kit/install.sh --project <name>

Flags:
  --project <name>        skill name becomes <name>-board (default: this repo's dir name)
  --main-branch <branch>  integration branch to install on (default: $BOARD_MAIN_BRANCH or main)
  --base-only             install the board + skill only; skip the orchestration agents/command
  --update                refresh skill/agents/command in place; leave .board/ data untouched
  -h, --help              show this help

It copies only the payload, runs `board init`, and stages the result — it never commits.
EOF
  exit "${1:-0}"
}

# ---------- parse flags ----------

PROJECT=""
MAIN_BRANCH="${BOARD_MAIN_BRANCH:-main}"
BASE_ONLY=0
UPDATE=0

while (($#)); do
  case "$1" in
    --project)     PROJECT="${2:-}"; shift 2 ;;
    --main-branch) MAIN_BRANCH="${2:-}"; shift 2 ;;
    --base-only)   BASE_ONLY=1; shift ;;
    --update)      UPDATE=1; shift ;;
    -h|--help)     usage 0 ;;
    *)             die "unknown argument: $1 (try --help)" ;;
  esac
done

# ---------- locate the kit payload (SRC) ----------

# BASH_SOURCE[0] is unset when piped via `curl … | bash` — guard against set -u.
SELF_SRC="${BASH_SOURCE[0]:-}"
if [[ -n "$SELF_SRC" ]]; then
  SELF_DIR=$(cd "$(dirname "$SELF_SRC")" && pwd -P)
else
  SELF_DIR=""
fi
CLONE_TMP=""
cleanup() { [[ -n "$CLONE_TMP" ]] && rm -rf "$CLONE_TMP"; }
trap cleanup EXIT

if [[ -f "$SELF_DIR/board/bin/board" ]]; then
  SRC="$SELF_DIR"
else
  command -v git >/dev/null 2>&1 || die "git is required"
  info "fetching board-kit from $BOARD_KIT_REPO …"
  CLONE_TMP=$(mktemp -d)
  git clone --depth 1 --quiet "$BOARD_KIT_REPO" "$CLONE_TMP" \
    || die "could not clone $BOARD_KIT_REPO (set BOARD_KIT_REPO to override)"
  SRC="$CLONE_TMP"
fi
[[ -f "$SRC/board/bin/board" && -f "$SRC/skill/SKILL.md" ]] \
  || die "kit payload not found under $SRC"

# ---------- target repo + preconditions ----------

command -v git >/dev/null 2>&1 || die "git is required"
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "not inside a git repository — run from the target repo root (git init first)"
ROOT=$(cd "$ROOT" && pwd -P)

# yq v4+ (mirrors board/bin/_lib.sh require_yq)
command -v yq >/dev/null 2>&1 || die "yq (v4+) is required. Install with: brew install yq"
YQ_V=$(yq --version 2>&1 | grep -oE 'v?[0-9]+' | head -1 | tr -d v)
[[ -n "$YQ_V" && "$YQ_V" -ge 4 ]] || die "yq v4+ required (found: $(yq --version 2>&1))"

# on the integration branch
BRANCH=$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)
[[ "$BRANCH" == "$MAIN_BRANCH" ]] \
  || die "checkout must be on '$MAIN_BRANCH' (currently: ${BRANCH:-detached HEAD}); use --main-branch to change"

# clean working tree, so the staged set stays tidy
git -C "$ROOT" diff --quiet --ignore-submodules HEAD 2>/dev/null \
  || die "working tree has uncommitted changes; commit or stash first"

# default project name = sanitized repo dir name
if [[ -z "$PROJECT" ]]; then
  PROJECT=$(basename "$ROOT")
fi
# kebab-case it (lowercase, non-alnum → -, trim), like _lib.sh:slugify
PROJECT=$(printf '%s' "$PROJECT" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
[[ -n "$PROJECT" ]] || die "could not derive a project name; pass --project <name>"

SKILL_DIR="$ROOT/.claude/skills/${PROJECT}-board"

# ---------- helpers ----------

# Copy the skill into place and rewrite its `name:` frontmatter to <project>-board.
install_skill() {
  mkdir -p "$SKILL_DIR"
  cp "$SRC/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
  local tmp
  tmp=$(mktemp)
  awk -v n="name: ${PROJECT}-board" '
    /^name:/ && !done { print n; done=1; next }
    { print }
  ' "$SKILL_DIR/SKILL.md" > "$tmp" && mv "$tmp" "$SKILL_DIR/SKILL.md"
}

# Copy the orchestration agents + command (names are cross-referenced — never renamed).
install_orchestration() {
  mkdir -p "$ROOT/.claude/agents" "$ROOT/.claude/commands"
  cp "$SRC/agents/ticket-implementer.md" "$ROOT/.claude/agents/"
  cp "$SRC/agents/ticket-reviewer.md"   "$ROOT/.claude/agents/"
  cp "$SRC/commands/clear-board.md"     "$ROOT/.claude/commands/"
}

# Paths to stage at the end (filled as we install).
STAGE=()

# ---------- update mode ----------

if [[ "$UPDATE" == "1" ]]; then
  [[ -d "$ROOT/.board" ]] || die ".board/ not found — run a fresh install (omit --update)"
  install_skill
  STAGE+=(".claude/skills/${PROJECT}-board")
  if [[ "$BASE_ONLY" == "0" ]]; then
    install_orchestration
    STAGE+=(".claude/agents/ticket-implementer.md" ".claude/agents/ticket-reviewer.md" ".claude/commands/clear-board.md")
  fi
  git -C "$ROOT" add "${STAGE[@]}"
  info "updated templates: ${STAGE[*]}"
  info ".board/ left untouched. Review and commit when ready."
  exit 0
fi

# ---------- fresh install ----------

[[ ! -e "$ROOT/.board" ]] || die ".board/ already exists — use --update to refresh templates, or remove it first"

cp -R "$SRC/board" "$ROOT/.board"
chmod +x "$ROOT/.board/bin/board" "$ROOT/.board/bin/_lib.sh"
STAGE+=(".board")

install_skill
STAGE+=(".claude/skills/${PROJECT}-board")

if [[ "$BASE_ONLY" == "0" ]]; then
  install_orchestration
  STAGE+=(".claude/agents/ticket-implementer.md" ".claude/agents/ticket-reviewer.md" ".claude/commands/clear-board.md")
fi

# Scaffold the columns + ID allocator via the board's own CLI.
BOARD_MAIN_BRANCH="$MAIN_BRANCH" "$ROOT/.board/bin/board" init

git -C "$ROOT" add "${STAGE[@]}"

# ---------- summary ----------

cat >&2 <<EOF

install: board kit installed in $ROOT
  board:   .board/  (skill: ${PROJECT}-board)$([[ "$BASE_ONLY" == "1" ]] && echo "  [base-only: no orchestration layer]")
  staged:  ${STAGE[*]}

Next steps:
  1. Review the staged files, then commit (this script does not commit).
  2. .board/bin/board doctor   # → board: clean
  3. .board/bin/board next     # list claimable tickets
EOF
if [[ "$MAIN_BRANCH" != "main" ]]; then
  echo "  • Integration branch is '$MAIN_BRANCH': export BOARD_MAIN_BRANCH=$MAIN_BRANCH so the CLI honors it." >&2
fi
echo "  • Point your agents at the board from CLAUDE.md (see INSTALL.md)." >&2
