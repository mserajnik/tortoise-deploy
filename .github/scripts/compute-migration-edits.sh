#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Walks the commits between the previous and current build of a stream via the
# GitHub API and records, under the stream's key in
# `.github/migration-edit-state.json`, the most recent commit that edited a
# world migration file (`sql/database_updates/*.sql` modified, renamed or
# removed; newly added files are normal and not recorded). A recorded edit is
# kept until a newer one supersedes it.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env GH_TOKEN
require_env TORTOISE_REPOSITORY_OWNER
require_env TORTOISE_REPOSITORY_NAME
require_env STATE_FILE
require_env STREAM_KEY
require_env CURRENT_COMMIT_HASH

repo="$TORTOISE_REPOSITORY_OWNER/$TORTOISE_REPOSITORY_NAME"
# shellcheck disable=SC2153
stream_key="$(trim "$STREAM_KEY")"
last_built_commit_hash="$(trim "${LAST_BUILT_COMMIT_HASH:-}")"
# shellcheck disable=SC2153
current_commit_hash="$(trim "$CURRENT_COMMIT_HASH")"

if [[ ! -f "$STATE_FILE" ]]; then
  fail "State file '$STATE_FILE' does not exist."
fi

if [[ -z "$last_built_commit_hash" ]]; then
  echo "No previous build for stream '$stream_key'; skipping migration-edit scan."
  exit 0
fi

if [[ "$last_built_commit_hash" == "$current_commit_hash" ]]; then
  echo "Last built and current commit are identical for stream '$stream_key'; nothing to scan."
  exit 0
fi

echo "Scanning $repo for world migration edits between $last_built_commit_hash and $current_commit_hash (stream '$stream_key')..."

# The compare endpoint returns commits oldest-first across pages; we reverse it
# so we can short-circuit on the newest edit.
commit_hashes_oldest_first="$(gh api --paginate \
  "repos/$repo/compare/$last_built_commit_hash...$current_commit_hash" \
  --jq '.commits[].sha')"

if [[ -z "$commit_hashes_oldest_first" ]]; then
  echo "No commits between $last_built_commit_hash and $current_commit_hash."
  exit 0
fi

commit_hashes_newest_first="$(tac <<<"$commit_hashes_oldest_first")"

latest_commit=""
latest_subject=""

# Each iteration makes one `gh api ...commits/<commit_hash>` call. The 5000
# calls per hour `GITHUB_TOKEN` rate limit bounds the worst case; the daily
# build cadence keeps each range small.
while IFS= read -r commit_hash; do
  [[ -z "$commit_hash" ]] && continue

  commit_data="$(gh api "repos/$repo/commits/$commit_hash")"

  # We skip merge commits because their diff against the first parent would
  # attribute the merged branch's file changes to the merge commit itself,
  # which would give us the wrong commit hash and subject.
  parent_count="$(jq -r '.parents | length' <<<"$commit_data")"
  if [[ "$parent_count" -ne 1 ]]; then
    continue
  fi

  has_edit="$(jq -r '
    [.files[]?
      | select(.status == "modified" or .status == "renamed" or .status == "removed")
      | select((.filename | test("^sql/database_updates/.*\\.sql$")) or ((.previous_filename // "") | test("^sql/database_updates/.*\\.sql$")))
    ] | length' <<<"$commit_data")"

  if [[ "$has_edit" -gt 0 ]]; then
    latest_commit="$commit_hash"
    latest_subject="$(jq -r '.commit.message | split("\n")[0]' <<<"$commit_data")"
    break
  fi
done <<<"$commit_hashes_newest_first"

if [[ -z "$latest_commit" ]]; then
  echo "No world migration edits for stream '$stream_key'; state file unchanged."
  exit 0
fi

echo "  - $stream_key: $latest_commit ($latest_subject)"

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
