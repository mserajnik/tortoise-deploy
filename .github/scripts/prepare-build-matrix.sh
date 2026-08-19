#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Decides which streams the default workflow builds this run and emits the
# build matrix consumed by the server and database build jobs. A stream is
# skipped when its moving tag (`stable` / `unstable`) already points at the
# current commit, unless the run is a scheduled Monday rebuild or a manual
# force rebuild. Each stream always gets its own build, including when `main`
# and `1181dev` resolve to the same commit: the two streams apply different
# patch sets and can carry different migration edits, so one image cannot
# represent both. Records any migration edit per stream in the state file and
# bakes it into each build's `migration_edits` so the database image can act on
# it.
#
# The cutoff anchors below are used only when the GitHub Container Registry
# yields no previous build's commit for a stream; subsequent runs resolve it
# from the registry instead.

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
require_env STATE_FILE

# The Tortoise-WoW commits we initially pinned for the drift check on `main`
# and `1181dev`. Both precede the first image built for their stream, so a scan
# starting here covers every commit that reached a user database.
TORTOISE_CUTOFF_STABLE="f1dbbf7549829a4fffe9a1f635581822d940ee81"
TORTOISE_CUTOFF_UNSTABLE="fee5caf96dbca685a1661a055e541a25fd8a4a60"

stable_commit="$(trim "$TORTOISE_STABLE_COMMIT_HASH")"
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

# shellcheck disable=SC2153
stable_last_built="$(last_built_commit_for_stream "$PACKAGE_OWNER" "$PACKAGE_NAME" "stable")"
unstable_last_built="$(last_built_commit_for_stream "$PACKAGE_OWNER" "$PACKAGE_NAME" "unstable")"

# The build decisions below use the resolved values as they are; an empty
# string forces a rebuild. The migration-edit scan instead needs a commit to
# walk from, so it falls back to the cutoff anchor.
stable_scan_floor="$stable_last_built"
if [[ -z "$stable_scan_floor" ]]; then
  echo "No prior package version with a commit hash tag found for stream 'stable'; falling back to migration edit cutoff."
  stable_scan_floor="$TORTOISE_CUTOFF_STABLE"
fi

unstable_scan_floor="$unstable_last_built"
if [[ -z "$unstable_scan_floor" ]]; then
  echo "No prior package version with a commit hash tag found for stream 'unstable'; falling back to migration edit cutoff."
  unstable_scan_floor="$TORTOISE_CUTOFF_UNSTABLE"
fi

stable_needs="false"
if [[ "$always_build" == "true" || "$stable_last_built" != "$stable_commit" ]]; then
  stable_needs="true"
fi

unstable_needs="false"
if [[ "$always_build" == "true" || "$unstable_last_built" != "$unstable_commit" ]]; then
  unstable_needs="true"
fi

# Record any migration edit per stream before building. Each stream is scanned
# against its own lineage, from the commit it was last built from or from its
# cutoff anchor when the registry has no such commit.
if [[ "$stable_needs" == "true" ]]; then
  run_compute "$stable_scan_floor" "$stable_commit" "stable"
fi
if [[ "$unstable_needs" == "true" ]]; then
  run_compute "$unstable_scan_floor" "$unstable_commit" "unstable"
fi

stable_migration_edits="$("$script_dir/migration-edits-to-arg.sh" "$STATE_FILE" "stable")"
unstable_migration_edits="$("$script_dir/migration-edits-to-arg.sh" "$STATE_FILE" "unstable")"

declare -a entries=()

add_entry() {
  entries+=("$(jq -nc \
    --arg stream "$1" \
    --arg tag_set "$2" \
    --arg commit_hash "$3" \
    --arg patch_set "$4" \
    --arg migration_edits "$5" \
    '{stream: $stream, tag_set: $tag_set, commit_hash: $commit_hash, patch_set: $patch_set, migration_edits: $migration_edits}')")
}

if [[ "$stable_needs" == "true" ]]; then
  add_entry "stable" "latest,stable" "$stable_commit" "stable" "$stable_migration_edits"
fi
if [[ "$unstable_needs" == "true" ]]; then
  add_entry "unstable" "unstable" "$unstable_commit" "unstable" "$unstable_migration_edits"
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
