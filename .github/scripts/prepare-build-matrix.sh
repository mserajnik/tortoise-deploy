#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Decides which streams the default workflow builds this run and emits the
# build matrix consumed by the server and database build jobs. A stream is
# skipped when its moving tag (`stable` / `unstable` / `customized`) already
# points at the current commit, unless the run is a scheduled Monday rebuild or
# a manual force rebuild. When `main` and `1181dev` resolve to the same commit,
# a single build carries `latest`, `stable`, and `unstable`. The `customized`
# stream is included only when the patches repository's `customized` directory
# holds at least one patch. Records any migration edit per stream in the state
# file and bakes it into each build's `migration_edits` so the database image
# can correct an existing world database on update.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env GH_TOKEN
require_env GITHUB_EVENT_NAME
require_env PACKAGE_OWNER
require_env PACKAGE_NAME
require_env TORTOISE_REPOSITORY_OWNER
require_env TORTOISE_REPOSITORY_NAME
require_env TORTOISE_STABLE_COMMIT_HASH
require_env TORTOISE_UNSTABLE_COMMIT_HASH
require_env PATCHES_REPOSITORY_OWNER
require_env PATCHES_REPOSITORY_NAME
require_env PATCHES_REVISION
require_env STATE_FILE

# shellcheck disable=SC2153
stable_commit="$(trim "$TORTOISE_STABLE_COMMIT_HASH")"
# shellcheck disable=SC2153
unstable_commit="$(trim "$TORTOISE_UNSTABLE_COMMIT_HASH")"
force_rebuild="${FORCE_REBUILD:-false}"
schedule_force_build="false"

if [[ "$GITHUB_EVENT_NAME" == "schedule" && "$(date +%u)" -eq 1 ]]; then
  schedule_force_build="true"
fi

always_build="false"
if [[ "$schedule_force_build" == "true" || "$force_rebuild" == "true" ]]; then
  always_build="true"
fi

customized_dir_is_populated() {
  local out
  local status

  set +e
  out="$(gh api \
    "repos/$PATCHES_REPOSITORY_OWNER/$PATCHES_REPOSITORY_NAME/contents/customized?ref=$PATCHES_REVISION" \
    --jq '[.[] | select(.type == "file") | select(.name | endswith(".patch"))] | length' 2>&1)"
  status=$?
  set -e

  if [[ $status -ne 0 ]]; then
    if grep -Fq "HTTP 404" <<<"$out"; then
      return 1
    fi
    printf '%s\n' "$out" >&2
    fail "Failed to query the customized patches directory."
  fi

  [[ "$out" -gt 0 ]]
}

run_compute() {
  local last_built="$1"
  local current="$2"
  local stream_key="$3"

  LAST_BUILT_COMMIT_HASH="$last_built" \
    CURRENT_COMMIT_HASH="$current" \
    STREAM_KEY="$stream_key" \
    STATE_FILE="$STATE_FILE" \
    "$script_dir/compute-migration-edits.sh"
}

# Flattens a stream's recorded edit to the `world:<commit-hash>` build argument
# the database image consumes (empty when the stream has no recorded edit).
migration_edit_arg_for_stream() {
  local stream_key="$1"
  local commit_hash

  commit_hash="$(jq -r --arg stream "$stream_key" '.[$stream].commit // ""' "$STATE_FILE")"

  if [[ -n "$commit_hash" ]]; then
    printf 'world:%s' "$commit_hash"
  fi
}

# shellcheck disable=SC2153
stable_last_built="$(last_built_commit_for_stream "$PACKAGE_OWNER" "$PACKAGE_NAME" "stable")"
unstable_last_built="$(last_built_commit_for_stream "$PACKAGE_OWNER" "$PACKAGE_NAME" "unstable")"
customized_last_built="$(last_built_commit_for_stream "$PACKAGE_OWNER" "$PACKAGE_NAME" "customized")"

shared="false"
if [[ "$stable_commit" == "$unstable_commit" ]]; then
  shared="true"
fi

stable_needs="false"
if [[ "$always_build" == "true" || "$stable_last_built" != "$stable_commit" ]]; then
  stable_needs="true"
fi

unstable_needs="false"
if [[ "$always_build" == "true" || "$unstable_last_built" != "$unstable_commit" ]]; then
  unstable_needs="true"
fi

customized_needs="false"
if customized_dir_is_populated; then
  if [[ "$always_build" == "true" || "$unstable_needs" == "true" || "$customized_last_built" != "$unstable_commit" ]]; then
    customized_needs="true"
  fi
fi

# Record any migration edit per stream before building. Each stream is scanned
# against its own lineage (the commit it was last built from). The `customized`
# stream builds from the same `1181dev` commit as `unstable`, so it reuses the
# `unstable` edit and is not scanned separately. In the shared-commit case both
# stream keys are advanced so neither goes stale once they diverge again.
if [[ "$shared" == "true" ]]; then
  if [[ "$stable_needs" == "true" || "$unstable_needs" == "true" ]]; then
    run_compute "$stable_last_built" "$stable_commit" "stable"
    run_compute "$unstable_last_built" "$unstable_commit" "unstable"
  fi
else
  if [[ "$stable_needs" == "true" ]]; then
    run_compute "$stable_last_built" "$stable_commit" "stable"
  fi
  if [[ "$unstable_needs" == "true" || "$customized_needs" == "true" ]]; then
    run_compute "$unstable_last_built" "$unstable_commit" "unstable"
  fi
fi

stable_migration_edits="$(migration_edit_arg_for_stream "stable")"
unstable_migration_edits="$(migration_edit_arg_for_stream "unstable")"

declare -a entries=()

add_entry() {
  entries+=("$(jq -nc \
    --arg tag_set "$1" \
    --arg commit_hash "$2" \
    --arg patch_set "$3" \
    --arg apply_customized "$4" \
    --arg tag_suffix "$5" \
    --arg migration_edits "$6" \
    '{tag_set: $tag_set, commit_hash: $commit_hash, patch_set: $patch_set, apply_customized: $apply_customized, tag_suffix: $tag_suffix, migration_edits: $migration_edits}')")
}

if [[ "$shared" == "true" ]]; then
  if [[ "$stable_needs" == "true" || "$unstable_needs" == "true" ]]; then
    add_entry "latest,stable,unstable" "$stable_commit" "stable" "0" "" "$stable_migration_edits"
  fi
else
  if [[ "$stable_needs" == "true" ]]; then
    add_entry "latest,stable" "$stable_commit" "stable" "0" "" "$stable_migration_edits"
  fi
  if [[ "$unstable_needs" == "true" ]]; then
    add_entry "unstable" "$unstable_commit" "unstable" "0" "" "$unstable_migration_edits"
  fi
fi

if [[ "$customized_needs" == "true" ]]; then
  add_entry "customized" "$unstable_commit" "unstable" "1" "-customized" "$unstable_migration_edits"
fi

if ((${#entries[@]} == 0)); then
  matrix="[]"
  any_images_to_build="false"
else
  matrix="$(printf '%s\n' "${entries[@]}" | jq -sc '.')"
  any_images_to_build="true"
fi

echo "Build matrix: $matrix"

write_output any_images_to_build "$any_images_to_build"
write_output matrix "$matrix"
