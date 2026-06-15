#!/usr/bin/env bash
# Shared helpers for the `board` dispatcher. Sourced, not executed.
# Conventions:
#   - All functions return non-zero on failure and print a one-line reason to stderr.
#   - Stdout is reserved for return values (paths, ids, lists).

set -euo pipefail

COLUMNS=(todo in-progress in-review blocked done)
# Branch that the board is mutated on. Override for repos that use master/trunk.
MAIN_BRANCH="${BOARD_MAIN_BRANCH:-main}"

die() { echo "board: $*" >&2; exit 1; }
warn() { echo "board: $*" >&2; }

require_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    die "yq (v4+) is required. Install with: brew install yq"
  fi
  local v
  v=$(yq --version 2>&1 | grep -oE 'v?[0-9]+' | head -1 | tr -d v)
  if [[ -z "$v" || "$v" -lt 4 ]]; then
    die "yq v4+ required (found: $(yq --version 2>&1))"
  fi
}

resolve_root() {
  # Honor BOARD_REPO_ROOT if set; otherwise walk up from this script.
  # Emit a *physical* path (pwd -P) so it matches `git rev-parse --show-toplevel`,
  # which resolves symlinks — otherwise repos under symlinked paths (e.g. macOS
  # /var → /private/var) fail the main-checkout check.
  if [[ -n "${BOARD_REPO_ROOT:-}" ]]; then
    (cd "$BOARD_REPO_ROOT" && pwd -P)
    return
  fi
  local here
  here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  # .board/bin/_lib.sh → repo root is two dirs up
  (cd "$here/../.." && pwd -P)
}

ROOT=$(resolve_root)
BOARD_DIR="$ROOT/.board"
WORKTREE_ROOT="$ROOT/../$(basename "$ROOT")-worktrees"

require_main_checkout() {
  local toplevel
  toplevel=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$toplevel" ]]; then
    die "$ROOT is not a git repository. Initialize git before using the board."
  fi
  if [[ "$toplevel" != "$ROOT" ]]; then
    die "must run from main checkout ($ROOT), not a worktree ($toplevel)"
  fi
  local branch
  branch=$(git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || true)
  if [[ "$branch" != "$MAIN_BRANCH" ]]; then
    die "main checkout must be on branch '$MAIN_BRANCH' (currently: ${branch:-detached HEAD})"
  fi
}

require_clean() {
  if ! git -C "$ROOT" diff --quiet --ignore-submodules HEAD 2>/dev/null; then
    die "working tree has uncommitted changes; commit or stash before board mutation"
  fi
}

# find_ticket <id> -> echoes absolute path; non-zero if not found or duplicated.
find_ticket() {
  local id="$1"
  local hits=()
  local col
  for col in "${COLUMNS[@]}"; do
    while IFS= read -r -d '' f; do
      hits+=("$f")
    done < <(find "$BOARD_DIR/$col" -maxdepth 1 -name "${id}-*.md" -print0 2>/dev/null)
  done
  if [[ ${#hits[@]} -eq 0 ]]; then
    warn "ticket $id not found in any column"
    return 1
  fi
  if [[ ${#hits[@]} -gt 1 ]]; then
    warn "ticket $id appears in multiple columns:"
    printf '  %s\n' "${hits[@]}" >&2
    return 1
  fi
  echo "${hits[0]}"
}

# Column of a ticket file path: e.g. .board/todo/T-001-foo.md -> todo
column_of() {
  basename "$(dirname "$1")"
}

# parse_slug <path> -> "T-NNN-slug" (filename without .md)
parse_slug() {
  basename "$1" .md
}

# Split frontmatter and body. Writes to two named temp files.
# Usage: split_frontmatter <file> <out_yaml> <out_body>
split_frontmatter() {
  local file="$1" yaml="$2" body="$3"
  awk -v y="$yaml" -v b="$body" '
    BEGIN { state = 0 }
    state == 0 && /^---[[:space:]]*$/ { state = 1; next }
    state == 1 && /^---[[:space:]]*$/ { state = 2; next }
    state == 1 { print > y; next }
    state == 2 { print > b }
  ' "$file"
  if [[ ! -s "$yaml" ]]; then
    die "no YAML frontmatter found in $file"
  fi
}

# Reassemble a markdown file from yaml + body temp files into <out>.
join_frontmatter() {
  local yaml="$1" body="$2" out="$3"
  {
    echo "---"
    cat "$yaml"
    echo "---"
    cat "$body"
  } > "$out"
}

# read_field <file> <field>  -> echoes value (or "null")
read_field() {
  local file="$1" field="$2"
  local yaml body
  yaml=$(mktemp); body=$(mktemp)
  trap 'rm -f "${yaml:-}" "${body:-}"' RETURN
  split_frontmatter "$file" "$yaml" "$body"
  yq ".$field" "$yaml"
}

# write_field <file> <field> <value>
# value is interpreted as a YAML expression: pass "null", "\"string\"", "[\"a\",\"b\"]", etc.
write_field() {
  local file="$1" field="$2" value="$3"
  local yaml body new
  yaml=$(mktemp); body=$(mktemp); new=$(mktemp)
  trap 'rm -f "${yaml:-}" "${body:-}" "${new:-}"' RETURN
  split_frontmatter "$file" "$yaml" "$body"
  yq -i ".$field = $value" "$yaml"
  join_frontmatter "$yaml" "$body" "$new"
  mv "$new" "$file"
}

# deps_satisfied <file> -> 0 if every depends_on id has a file in done/; else 1.
deps_satisfied() {
  local file="$1"
  local yaml body
  yaml=$(mktemp); body=$(mktemp)
  trap 'rm -f "${yaml:-}" "${body:-}"' RETURN
  split_frontmatter "$file" "$yaml" "$body"
  local deps
  deps=$(yq -r '.depends_on[]?' "$yaml" 2>/dev/null || true)
  if [[ -z "$deps" ]]; then return 0; fi
  local id
  while IFS= read -r id; do
    [[ -z "$id" ]] && continue
    if ! find "$BOARD_DIR/done" -maxdepth 1 -name "${id}-*.md" 2>/dev/null | grep -q .; then
      warn "  unmet dependency: $id (not in done/)"
      return 1
    fi
  done <<< "$deps"
  return 0
}

iso_now() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

NEXT_ID_FILE() { echo "$BOARD_DIR/.next-id"; }

read_next_id() {
  local f
  f=$(NEXT_ID_FILE)
  [[ -f "$f" ]] || die "missing $f — initialize with: echo 1 > $f"
  local n
  n=$(tr -d '[:space:]' < "$f")
  [[ "$n" =~ ^[0-9]+$ ]] || die ".next-id is not an integer: $n"
  echo "$n"
}

write_next_id() {
  local n="$1"
  echo "$n" > "$(NEXT_ID_FILE)"
}

# Highest existing T-id across all columns, or 0 if none.
max_existing_id() {
  local max=0
  local f id n
  for f in "$BOARD_DIR"/{todo,in-progress,in-review,blocked,done}/T-*.md; do
    [[ -e "$f" ]] || continue
    id=$(basename "$f" | grep -oE '^T-[0-9]+')
    n=${id#T-}; n=$((10#$n))
    (( n > max )) && max=$n
  done
  echo "$max"
}

# Pad an integer to T-NNN with at least 3 digits.
format_id() {
  printf 'T-%03d' "$1"
}

# Derive a kebab-case slug from a title, max 40 chars.
slugify() {
  local s="$1"
  s=$(echo "$s" | tr '[:upper:]' '[:lower:]')
  s=$(echo "$s" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')
  echo "${s:0:40}" | sed -E 's/-+$//'
}

# Validate an id string looks like T-NNN.
is_ticket_id() {
  [[ "$1" =~ ^T-[0-9]+$ ]]
}

# Validate every id in a comma-separated list exists somewhere on the board.
# Refuses if any id is unknown. Empty list is fine.
validate_dep_ids() {
  local list="$1"
  [[ -z "$list" ]] && return 0
  local id
  for id in ${list//,/ }; do
    is_ticket_id "$id" || die "not a ticket id: $id"
    find_ticket "$id" >/dev/null 2>&1 || die "unknown dep: $id (no ticket file)"
  done
}

confirm() {
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
  read -r -p "$1 [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]]
}
