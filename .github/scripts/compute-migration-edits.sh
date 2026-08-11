#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Walks the commits between the previous and current build of a stream and
# records, under the stream's key in `.github/migration-edit-state.json`, the
# most recent commit that edited the world database's SQL sources. A recorded
# edit is kept until a newer one supersedes it.
#
# Two sources are watched, with deliberately different file statuses:
#
# - `sql/database_updates/**/*.sql`, modified, renamed or removed. A newly
#   added migration is normal; the server applies it forward on the next start,
#   so it needs no remedy.
# - `sql/base/**/*.sql`, added as well as modified, renamed or removed. Base
#   dumps are imported once when the database is created and never re-read, so
#   an added dump is as invisible to an existing database as an edited one.
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
# shellcheck disable=SC2153
last_built_commit_hash="$(trim "$LAST_BUILT_COMMIT_HASH")"
# shellcheck disable=SC2153
current_commit_hash="$(trim "$CURRENT_COMMIT_HASH")"

# The backslashes are doubled because `awk -v` processes escape sequences in
# the value.
updates_pattern='^sql/database_updates/.*\\.sql$'
base_pattern='^sql/base/.*\\.sql$'
base_exclude_pattern='^sql/base/tw_world_migrations\\.sql$'

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

# Merge commits are excluded because their diff against the first parent would
# attribute the merged branch's file changes to the merge commit itself, which
# would give us the wrong commit hash and subject.
commit_hashes_newest_first="$(git -C "$clone_dir" rev-list --no-merges --topo-order \
  "$last_built_commit_hash..$current_commit_hash")"

if [[ -z "$commit_hashes_newest_first" ]]; then
  echo "No commits between $last_built_commit_hash and $current_commit_hash."
  exit 0
fi

commit_hashes_total="$(wc -l <<<"$commit_hashes_newest_first")"
echo "Walking $commit_hashes_total commits newest-first."

latest_commit=""
latest_subject=""
scanned=0

while IFS= read -r commit_hash; do
  [[ -z "$commit_hash" ]] && continue
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

  # The exclusion is tested against the new path only.
  has_edit="$(awk -F'\t' \
    -v updates_pattern="$updates_pattern" \
    -v base_pattern="$base_pattern" \
    -v base_exclude_pattern="$base_exclude_pattern" '
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
      matches_base = (path ~ base_pattern) ||
        (previous_path != "" && previous_path ~ base_pattern)

      if (status ~ /^[MRDT]$/ && matches_updates) {
        found = 1
      }

      if (status ~ /^[AMRDT]$/ && matches_base &&
        path !~ base_exclude_pattern) {
        found = 1
      }
    }
    END { if (found) print "1" }' <<<"$changed_files")"

  if [[ "$has_edit" == "1" ]]; then
    latest_commit="$commit_hash"
    latest_subject="$(git -C "$clone_dir" log -1 --format=%s "$commit_hash")"
    echo "  - $stream_key: $latest_commit ($latest_subject)"
    break
  fi
done <<<"$commit_hashes_newest_first"

echo "Scanned $scanned commit(s)."

if [[ -z "$latest_commit" ]]; then
  echo "No new migration edits for stream '$stream_key'; state file unchanged."
  exit 0
fi

new_state="$(jq \
  --arg stream "$stream_key" \
  --arg commit_hash "$latest_commit" \
  --arg subject "$latest_subject" \
  '.[$stream] = {commit: $commit_hash, subject: $subject}' \
  "$STATE_FILE")"

existing_state="$(<"$STATE_FILE")"
if [[ "$new_state" == "$existing_state" ]]; then
  echo "'$STATE_FILE' already up to date."
  exit 0
fi

printf '%s\n' "$new_state" >"$STATE_FILE"
echo "Updated '$STATE_FILE'."
