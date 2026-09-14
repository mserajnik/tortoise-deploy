#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Walks the commits between the previous and current build of a unit and
# updates `.github/migration-edit-state.json` with the most recent commit that
# edited each target database's SQL sources. A recorded edit is kept until a
# newer one supersedes it.
#
# Each target has one entry per source the edit came from. Where the database
# image can re-create the target, the entry is a bare object. Where the
# operator has to fix it by hand, the entry is a list.
#
# Targets are classified by directory, which is how the server itself decides
# where a migration goes: `AutoUpdater::ProcessUpdates` joins
# `Database.AutoUpdate.Path` with one folder name per database and iterates
# each of them non-recursively. A flat layout has no per-database folder, so a
# file directly in `sql/database_updates/` counts as world.
#
# The watch covers migration directories and base dumps, and each takes a
# different set of file statuses:
#
# - Migration directories, modified, renamed, or removed. A newly added
#   migration is normal. The server applies it forward on the next start. This
#   covers the core's `sql/database_updates/` and a module's `data/sql/`.
# - `sql/base/`, added as well as modified, renamed or removed. Base dumps are
#   imported once when the database is created and never re-read, so an added
#   dump is as invisible to an existing database as an edited one. Only the
#   world database imports from there, and such dumps come from the core alone.
#
# `sql/base/tw_world_migrations.sql` is excluded; it dumps the auto-updater's
# own bookkeeping table rather than world data. `check-upstream-drift.sh`
# watches it instead.
#
# The walk reads a blobless clone rather than the GitHub API, whose commit
# endpoint silently caps a file list and could hide a watched file.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env SOURCE
require_env SOURCE_REPOSITORY_OWNER
require_env SOURCE_REPOSITORY_NAME
require_env STATE_FILE
require_env UNITS
require_env LAST_BUILT_COMMIT_HASH
require_env CURRENT_COMMIT_HASH

repo="$SOURCE_REPOSITORY_OWNER/$SOURCE_REPOSITORY_NAME"
# The name avoids `source`, which is a shell builtin.
# shellcheck disable=SC2153
source_name="$(trim "$SOURCE")"
case "$source_name" in
  core | tortoisebots) ;;
  *) fail "Unsupported source '$source_name'." ;;
esac

# The core's window is the same for `base` and for `modules-bots`, which builds
# from the same commit. One walk covers both. Scanning once per unit would
# clone and walk identical commits for an identical answer.
# shellcheck disable=SC2153
IFS=',' read -r -a units <<<"$(trim "$UNITS")"
if ((${#units[@]} == 0)); then
  fail "Environment variable 'UNITS' names no unit."
fi
# jq would create a key that is not there, so an unrecognized unit writes the
# edit where nothing reads it.
for unit in "${units[@]}"; do
  case "$unit" in
    base | modules-bots) ;;
    *) fail "Unsupported unit '$unit'." ;;
  esac
done
# shellcheck disable=SC2153
last_built_commit_hash="$(trim "$LAST_BUILT_COMMIT_HASH")"
# shellcheck disable=SC2153
current_commit_hash="$(trim "$CURRENT_COMMIT_HASH")"

db_names=(world character)
db_kinds=(recreate manual)

# The paths a watch covers for a source, and the directories every `.sql` has
# to fall into, both differ per source. `awk -v` processes escape sequences in
# the value. The patterns below double their backslashes for that reason.
case "$source_name" in
  core)
    watched_roots=(sql/base/ sql/database_updates/)
    db_updates_patterns=(
      '^sql/database_updates/([^/]+|world/[^/]+)\\.sql$'
      '^sql/database_updates/character/[^/]+\\.sql$'
    )
    # Only the world database receives base dumps. An empty pattern turns the
    # base checks off for every other target. The pattern matches the world
    # database alone. The layout check below then catches a dump for any other
    # database.
    db_base_patterns=(
      '^sql/base/tw_world_[^/]+\\.sql$'
      ''
    )
    db_base_exclude_patterns=(
      '^sql/base/tw_world_migrations\\.sql$'
      ''
    )
    # The server applies migrations under `<folder>/cn/` only with the `NiHao`
    # configuration option turned on. This deployment never sets it. The layout
    # check below exempts them.
    regional_pattern='^sql/database_updates/[^/]+/cn/[^/]+\\.sql$'
    ;;
  tortoisebots)
    # The module calls its source directory `char` and installs it as
    # `character`. The names here are the module's.
    #
    # A module does not provide a base dump. Its migrations create its tables,
    # so a database created before any of those files existed missed nothing.
    watched_roots=(data/sql/)
    db_updates_patterns=(
      '^data/sql/world/[^/]+\\.sql$'
      '^data/sql/char/[^/]+\\.sql$'
    )
    db_base_patterns=('' '')
    db_base_exclude_patterns=('' '')
    regional_pattern=''
    ;;
esac

# A state file jq cannot read as an object would make the writeback's
# comparison read as "already up to date" and silently drop an edit the walk
# just found. `version` marks this shape, so the flat one that preceded it
# cannot pass as a valid state.
if ! jq -e '
  type == "object"
  and .version == 1
  and .source_kind == "repository"
  and (.streams | type) == "object"
  and all(.streams[]; type == "object"
      and (keys_unsorted - ["world", "character"]) == []
      and all(.[]; type == "object"
          and (keys_unsorted - ["core", "tortoisebots"]) == []
          and all(.[];
                (type == "object" and has("commit"))
                or (type == "array" and length > 0
                    and all(.[]; type == "object" and has("commit"))))))
  and all(.. | objects | select(has("commit")) | .commit;
          type == "string" and length == 40 and test("^[0-9a-f]{40}$"))
' "$STATE_FILE" >/dev/null; then
  fail "State file '$STATE_FILE' is missing, is not a version 1 repository-sourced state object with 'world' and 'character' targets and 'core' and 'tortoisebots' sources, or holds a malformed commit hash."
fi

units_label="$(
  IFS=,
  printf '%s' "${units[*]}"
)"

if [[ "$last_built_commit_hash" == "$current_commit_hash" ]]; then
  echo "Last built and current commit are identical for source '$source_name'; nothing to scan."
  exit 0
fi

echo "Scanning '$repo' for migration edits between $last_built_commit_hash and $current_commit_hash (source '$source_name', unit(s) '$units_label')..."

clone_dir="$(mktemp -d)"
trap 'rm -rf "$clone_dir"' EXIT

# Blobless so the clone carries commits and trees but no file contents, which
# is all `git diff-tree` needs to report paths and statuses.
git clone --filter=blob:none --no-checkout --quiet \
  "https://github.com/$repo.git" "$clone_dir"

# The floor and the tip can both stop being reachable. Say which revision is
# missing. The blobless clone's lazy fetch gives only a raw `not our ref`.
for revision in "$last_built_commit_hash" "$current_commit_hash"; do
  if ! git -C "$clone_dir" cat-file -e "$revision^{commit}"; then
    fail "Commit $revision is not available in '$repo'."
  fi
done

# Every `.sql` under the watched directories has to belong to a target, because
# the applier reads each directory whole while the patterns below set what a
# remedy can cover. A path that matches no target is a change this script
# cannot classify, and it fails the build for review. For a module this also
# covers a new sibling directory. SQL outside the directories the applier reads
# would go into the image and never run, and SQL inside one it does read would
# apply with nothing watching it.
#
# `core.quotePath=false` unquotes non-ASCII bytes but not a path Git still has
# to escape; such a path is kept by its leading quote, because it matches no
# target pattern either.
unclassified_paths="$(git -C "$clone_dir" -c core.quotePath=false ls-tree \
  -r --name-only "$current_commit_hash" -- "${watched_roots[@]}" |
  awk '/\.sql$/ || /^"/')"

for i in "${!db_names[@]}"; do
  unclassified_paths="$(awk -v pattern="${db_updates_patterns[$i]}" \
    '$0 !~ pattern' <<<"$unclassified_paths")"

  # An empty pattern would drop every remaining path rather than none.
  if [[ -n "${db_base_patterns[$i]}" ]]; then
    unclassified_paths="$(awk -v pattern="${db_base_patterns[$i]}" \
      '$0 !~ pattern' <<<"$unclassified_paths")"
  fi
done

if [[ -n "$regional_pattern" ]]; then
  unclassified_paths="$(awk -v pattern="$regional_pattern" \
    '$0 !~ pattern' <<<"$unclassified_paths")"
fi

if [[ -n "$unclassified_paths" ]]; then
  echo "Migration files at $current_commit_hash that belong to no target database:" >&2
  while IFS= read -r unclassified_path; do
    printf '  %s\n' "$unclassified_path" >&2
  done <<<"$unclassified_paths"

  fail "Classify the path(s) above, either by adding a target or by widening an existing pattern, before building."
fi

# This skips merge commits, because `git diff-tree` reports nothing for one
# against its first parent. A merge that resolves a conflict by hand introduces
# content no other commit has, and this walk does not see it.
commit_hashes_newest_first="$(git -C "$clone_dir" rev-list --no-merges --topo-order \
  "$last_built_commit_hash..$current_commit_hash")"

if [[ -z "$commit_hashes_newest_first" ]]; then
  # An empty window usually means nothing new. It also means the floor is ahead
  # of the tip, which upstream rewinding a branch produces. The messages below
  # say which of the two it is.
  if git -C "$clone_dir" merge-base --is-ancestor \
    "$current_commit_hash" "$last_built_commit_hash"; then
    echo "Current commit $current_commit_hash is an ancestor of the last built commit $last_built_commit_hash; the scan floor is ahead of the tip."
    exit 0
  fi

  echo "No non-merge commits between $last_built_commit_hash and $current_commit_hash."
  exit 0
fi

commit_hashes_total="$(wc -l <<<"$commit_hashes_newest_first")"
echo "Walking $commit_hashes_total commit(s) newest-first."

latest_commits=("" "")
latest_subjects=("" "")

found_count=0
scanned=0

while IFS= read -r commit_hash; do
  [[ -z "$commit_hash" ]] && continue

  # We're walking newest-first, so once every target has a hit, no later commit
  # can win.
  if [[ "$found_count" -eq "${#db_names[@]}" ]]; then
    break
  fi

  scanned=$((scanned + 1))

  # `core.quotePath` defaults to true, which wraps a path holding a non-ASCII
  # byte in quotes and escapes it, and no watched pattern matches such a value.
  #
  # Rename detection is limited to exact matches because the similarity scoring
  # `-M` performs otherwise reads file contents, which a blobless clone has to
  # fetch one commit at a time. A rename reports both its old and its new path,
  # and the checks below test both, so a watched file renamed away still
  # counts. A rename within one target counts as well, which the applier would
  # have handled on its own.
  #
  # A parentless commit reports nothing at all without `--root`, so an
  # unrelated history grafted into the window would pass as touching no watched
  # file. The flag changes nothing for every other commit.
  changed_files="$(git -C "$clone_dir" -c core.quotePath=false diff-tree \
    --no-commit-id --name-status --root -r -M100% "$commit_hash")"

  for i in "${!db_names[@]}"; do
    if [[ -n "${latest_commits[$i]}" ]]; then
      continue
    fi

    # The exclusion is tested against the new path only.
    has_edit="$(awk -F'\t' \
      -v updates_pattern="${db_updates_patterns[$i]}" \
      -v base_pattern="${db_base_patterns[$i]}" \
      -v base_exclude_pattern="${db_base_exclude_patterns[$i]}" '
      {
        status = substr($1, 1, 1)

        if (status == "R") {
          previous_path = $2
          path = $3
        } else {
          previous_path = ""
          path = $2
        }

        matches_updates = (path ~ updates_pattern) ||
          (previous_path != "" && previous_path ~ updates_pattern)
        matches_base = base_pattern != "" &&
          ((path ~ base_pattern) ||
            (previous_path != "" && previous_path ~ base_pattern))

        if (status ~ /^[MRDT]$/ && matches_updates) {
          found = 1
        }

        if (status ~ /^[AMRDT]$/ && matches_base &&
          (base_exclude_pattern == "" || path !~ base_exclude_pattern)) {
          found = 1
        }
      }
      END { if (found) print "1" }' <<<"$changed_files")"

    if [[ "$has_edit" == "1" ]]; then
      subject="$(git -C "$clone_dir" log -1 --format=%s "$commit_hash")"
      latest_commits[i]="$commit_hash"
      latest_subjects[i]="$subject"
      found_count=$((found_count + 1))
      echo "  - $units_label/${db_names[$i]}/$source_name: $commit_hash ($subject)"
    fi
  done
done <<<"$commit_hashes_newest_first"

echo "Scanned $scanned commit(s); found edits for $found_count target(s)."

if [[ "$found_count" -eq 0 ]]; then
  echo "No new migration edits for source '$source_name'; state file unchanged."
  exit 0
fi

# The single-quoted string is a jq filter, not a Bash expression; `$existing`
# and `$unit` are jq variables. Rebuilding the unit's object from the target
# list is what drops a target that is no longer watched, and every watched
# target keeps a key even when nothing is recorded under it. The top-level key
# is `streams` because that is the key docker-deploy-actions reads and writes.
# shellcheck disable=SC2016
state_filter='. as $existing | .streams[$unit] = {'
for i in "${!db_names[@]}"; do
  if [[ "$i" -gt 0 ]]; then
    state_filter+=','
  fi
  state_filter+=" \"${db_names[$i]}\": (\$existing.streams[\$unit].\"${db_names[$i]}\" // {})"
done
state_filter+=' }'

new_state="$(<"$STATE_FILE")"

# The walk found one answer per target. Every unit built from this source
# records that same answer under its own key. Each unit is then
# self-describing. A reader can take one unit's entry at face value without
# knowing which units share a walk.
for unit in "${units[@]}"; do
  new_state="$(jq --arg unit "$unit" "$state_filter" <<<"$new_state")"

  for i in "${!db_names[@]}"; do
    if [[ -z "${latest_commits[$i]}" ]]; then
      continue
    fi

    # `edit_filter` persists across iterations. Clearing it first makes a kind
    # with no arm below fail on an unbound variable.
    unset edit_filter
    # Both values are jq filters. `$commit_hash` and `$subject` are jq
    # variables bound below. In a `manual` target's list, index 0 is the newest
    # edit, which is where `migration-edits-to-arg.sh` reads it from.
    # shellcheck disable=SC2016
    case "${db_kinds[$i]}" in
      recreate) edit_filter='{commit: $commit_hash, subject: $subject}' ;;
      manual) edit_filter='[{commit: $commit_hash, subject: $subject}]' ;;
    esac

    new_state="$(jq \
      --arg unit "$unit" \
      --arg db "${db_names[$i]}" \
      --arg source_name "$source_name" \
      --arg commit_hash "${latest_commits[$i]}" \
      --arg subject "${latest_subjects[$i]}" \
      ".streams[\$unit][\$db][\$source_name] = $edit_filter" \
      <<<"$new_state")"
  done
done

existing_state="$(<"$STATE_FILE")"
if [[ "$new_state" == "$existing_state" ]]; then
  echo "'$STATE_FILE' already up to date."
  exit 0
fi

printf '%s\n' "$new_state" >"$STATE_FILE"
echo "Updated '$STATE_FILE'."
