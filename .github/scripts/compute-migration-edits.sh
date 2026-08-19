#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Walks the commits between the previous and current build of a stream and
# updates `.github/migration-edit-state.json` with the most recent commit that
# edited each target database's SQL sources. A recorded edit is kept until a
# newer one supersedes it.
#
# Targets are classified by directory, which is how the server itself decides
# where a migration goes: `AutoUpdater::ProcessUpdates` joins
# `Database.AutoUpdate.Path` with one folder name per database and iterates
# each of them non-recursively. A flat layout has no per-database folder, so a
# file directly in `sql/database_updates/` counts as world.
#
# Two sources are watched, with deliberately different file statuses:
#
# - `sql/database_updates/`, modified, renamed or removed. A newly added
#   migration is normal; the server applies it forward on the next start, so it
#   needs no remedy.
# - `sql/base/`, added as well as modified, renamed or removed. Base dumps are
#   imported once when the database is created and never re-read, so an added
#   dump is as invisible to an existing database as an edited one. Only the
#   world database is imported from there.
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

require_env TORTOISE_REPOSITORY_OWNER
require_env TORTOISE_REPOSITORY_NAME
require_env STATE_FILE
require_env STREAM_KEY
require_env LAST_BUILT_COMMIT_HASH
require_env CURRENT_COMMIT_HASH

repo="$TORTOISE_REPOSITORY_OWNER/$TORTOISE_REPOSITORY_NAME"
# shellcheck disable=SC2153
stream_key="$(trim "$STREAM_KEY")"
# `jq` would create a key that is not there, so an unrecognized stream writes
# the edit into a top-level key nothing reads.
case "$stream_key" in
  stable | unstable) ;;
  *) fail "Unsupported stream '$stream_key'." ;;
esac
# shellcheck disable=SC2153
last_built_commit_hash="$(trim "$LAST_BUILT_COMMIT_HASH")"
# shellcheck disable=SC2153
current_commit_hash="$(trim "$CURRENT_COMMIT_HASH")"

db_names=(world character)

# The backslashes are doubled because `awk -v` processes escape sequences in
# the value.
db_updates_patterns=(
  '^sql/database_updates/([^/]+|world/[^/]+)\\.sql$'
  '^sql/database_updates/character/[^/]+\\.sql$'
)
# Only the world database receives base dumps; an empty pattern turns the base
# checks off for every other target. The pattern names the database rather than
# accepting everything under `sql/base/`, so a dump for a database no target
# claims reaches the layout check below instead of being watched as world.
db_base_patterns=(
  '^sql/base/tw_world_[^/]+\\.sql$'
  ''
)
db_base_exclude_patterns=(
  '^sql/base/tw_world_migrations\\.sql$'
  ''
)

# Migrations under `<folder>/cn/` are applied only when the `NiHao` config
# option is enabled, which we never set, so they are exempt from the layout
# check below rather than assigned to a target.
regional_pattern='^sql/database_updates/[^/]+/cn/[^/]+\\.sql$'

# A state file `jq` cannot read as an object would make the writeback's
# comparison read as "already up to date" and silently drop an edit the walk
# just found.
if ! jq -e '
  type == "object"
  and all(.. | objects | select(has("commit")) | .commit;
          type == "string" and length == 40 and test("^[0-9a-f]{40}$"))
' "$STATE_FILE" >/dev/null; then
  fail "State file '$STATE_FILE' is missing, is not a JSON object, or holds a malformed commit hash."
fi

if [[ "$last_built_commit_hash" == "$current_commit_hash" ]]; then
  echo "Last built and current commit are identical for stream '$stream_key'; nothing to scan."
  exit 0
fi

echo "Scanning '$repo' for migration edits between $last_built_commit_hash and $current_commit_hash (stream '$stream_key')..."

clone_dir="$(mktemp -d)"
trap 'rm -rf "$clone_dir"' EXIT

# Blobless so the clone carries commits and trees but no file contents, which
# is all `git diff-tree` needs to report paths and statuses.
git clone --filter=blob:none --no-checkout --quiet \
  "https://github.com/$repo.git" "$clone_dir"

# Every `.sql` under the two watched directories has to belong to a target,
# because both are consumed wholesale (the server applies what it finds in one,
# `create-db.sh` imports the other) while our patterns decide what we can ever
# remedy. A path no target claims is therefore treated as a change we cannot
# reason about and fails the build for review.
#
# `core.quotePath=false` unquotes non-ASCII bytes but not a path Git still has
# to escape; such a path is kept by its leading quote, because it matches no
# target pattern either.
unclassified_paths="$(git -C "$clone_dir" -c core.quotePath=false ls-tree \
  -r --name-only "$current_commit_hash" -- sql/base/ sql/database_updates/ |
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

unclassified_paths="$(awk -v pattern="$regional_pattern" \
  '$0 !~ pattern' <<<"$unclassified_paths")"

if [[ -n "$unclassified_paths" ]]; then
  echo "Migration files at $current_commit_hash that belong to no target database:" >&2
  while IFS= read -r unclassified_path; do
    printf '  %s\n' "$unclassified_path" >&2
  done <<<"$unclassified_paths"

  fail "Classify the path(s) above, either by adding a target or by widening an existing pattern, before building."
fi

# Merge commits are excluded because `git diff-tree` reports nothing for them,
# so walking one could only ever yield an empty result.
commit_hashes_newest_first="$(git -C "$clone_dir" rev-list --no-merges --topo-order \
  "$last_built_commit_hash..$current_commit_hash")"

if [[ -z "$commit_hashes_newest_first" ]]; then
  echo "No commits between $last_built_commit_hash and $current_commit_hash."
  exit 0
fi

commit_hashes_total="$(wc -l <<<"$commit_hashes_newest_first")"
echo "Walking $commit_hashes_total commits newest-first."

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
  # counts.
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
      echo "  - $stream_key/${db_names[$i]}: $commit_hash ($subject)"
    fi
  done
done <<<"$commit_hashes_newest_first"

echo "Scanned $scanned commit(s); found edits for $found_count target(s)."

if [[ "$found_count" -eq 0 ]]; then
  echo "No new migration edits for stream '$stream_key'; state file unchanged."
  exit 0
fi

# The single-quoted string is a jq filter, not a bash expression; `$existing`
# and `$stream` are jq variables. Rebuilding the stream's object from the
# target list is what drops a target that is no longer watched.
# shellcheck disable=SC2016
state_filter='. as $existing | .[$stream] = {'
for i in "${!db_names[@]}"; do
  if [[ "$i" -gt 0 ]]; then
    state_filter+=','
  fi
  state_filter+=" \"${db_names[$i]}\": \$existing[\$stream].\"${db_names[$i]}\""
done
state_filter+=' }'

new_state="$(jq --arg stream "$stream_key" "$state_filter" "$STATE_FILE")"

for i in "${!db_names[@]}"; do
  if [[ -n "${latest_commits[$i]}" ]]; then
    new_state="$(jq \
      --arg stream "$stream_key" \
      --arg db "${db_names[$i]}" \
      --arg commit_hash "${latest_commits[$i]}" \
      --arg subject "${latest_subjects[$i]}" \
      '.[$stream][$db] = {commit: $commit_hash, subject: $subject}' \
      <<<"$new_state")"
  fi
done

existing_state="$(<"$STATE_FILE")"
if [[ "$new_state" == "$existing_state" ]]; then
  echo "'$STATE_FILE' already up to date."
  exit 0
fi

printf '%s\n' "$new_state" >"$STATE_FILE"
echo "Updated '$STATE_FILE'."
