#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Decides which streams the default workflow builds this run and emits the
# build units consumed by the server and database build jobs. A stream is
# skipped when its moving tag (`stable` / `unstable`) already points at the
# current commit, unless the run is a scheduled Monday rebuild or a manual
# force rebuild. Each stream always gets its own build, including when `main`
# and `1181dev` resolve to the same commit: the two streams apply different
# patch sets and can carry different migration edits, so one image cannot
# represent both. Records any migration edit per stream in the state file and
# bakes it into each build's `migration_edits` so the database image can act on
# it.
#
# A unit is one build leg. Every stream is a unit, and when modules are
# requested each stream also gets a `<stream>-modules` unit carrying the
# bundled module set. A variant unit is built exactly when its stream is, so
# there is no second build decision; it produces a server image only, sharing
# its stream's database image, and it is not a key in the state file. Hence the
# two separate lists: the server job builds every unit, the database job only
# the streams.
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

# The bundled module set, packed into the single `TORTOISE_MODULES` build
# argument the server Dockerfile takes: `<directory>=<url>@<revision>` entries
# separated by `|`. The directory name is the module repository's name, because
# that is the name the generated module loader derives its symbol from. Modules
# are opt-in; without them no variant unit is emitted at all.
declare -a module_entries=()

add_module() {
  local repository="$1"
  local commit_hash="$2"

  module_entries+=("${repository##*/}=https://github.com/$repository.git@$commit_hash")
}

if [[ -n "${TW_MOD_AUTOSCALE_REPOSITORY:-}${TW_MOD_AUTOSCALE_COMMIT_HASH:-}" ]]; then
  require_env TW_MOD_AUTOSCALE_REPOSITORY
  require_env TW_MOD_AUTOSCALE_COMMIT_HASH

  add_module "$TW_MOD_AUTOSCALE_REPOSITORY" "$TW_MOD_AUTOSCALE_COMMIT_HASH"
fi
if [[ -n "${TW_MOD_LEECH_REPOSITORY:-}${TW_MOD_LEECH_COMMIT_HASH:-}" ]]; then
  require_env TW_MOD_LEECH_REPOSITORY
  require_env TW_MOD_LEECH_COMMIT_HASH

  add_module "$TW_MOD_LEECH_REPOSITORY" "$TW_MOD_LEECH_COMMIT_HASH"
fi

modules=""
module_licenses=""
if ((${#module_entries[@]} > 0)); then
  # Required rather than optional: a variant image whose license annotation
  # silently omits its modules' licenses is worse than a failed run. Checked
  # after the trim, so a whitespace-only value cannot pass here and then empty
  # itself further down the workflow.
  module_licenses="$(trim "${MODULE_LICENSES:-}")"
  if [[ -z "$module_licenses" ]]; then
    fail "Environment variable 'MODULE_LICENSES' is required."
  fi
  printf -v modules '%s|' "${module_entries[@]}"
  modules="${modules%|}"
  echo "Bundled module set: $modules"
fi

declare -a server_units=()
declare -a database_units=()
declare -a metadata_entries=()

add_metadata() {
  metadata_entries+=("$(jq -nc \
    --arg unit "$1" \
    --arg tag_set "$2" \
    --arg commit_hash "$3" \
    --arg patch_set "$4" \
    --arg migration_edits "$5" \
    --arg modules "$6" \
    --arg module_licenses "$7" \
    --arg database_alias_units "$8" \
    '{
       ($unit): {
         tag_set: $tag_set,
         commit_hash: $commit_hash,
         patch_set: $patch_set,
         migration_edits: $migration_edits,
         modules: $modules,
         module_licenses: $module_licenses,
         database_alias_units: $database_alias_units
       }
     }')")
}

# Records one stream: one server image and one database image from the same
# commit. The database image is also published under the stream's variants,
# which share it; only the server job builds a variant of its own.
add_stream() {
  local stream="$1"
  local tag_set="$2"
  local commit_hash="$3"
  local migration_edits="$4"
  local database_alias_units=""

  if [[ -n "$modules" ]]; then
    database_alias_units="$stream-modules"
  fi

  server_units+=("$stream")
  database_units+=("$stream")
  add_metadata "$stream" "$tag_set" "$commit_hash" "$stream" "$migration_edits" \
    "" "" "$database_alias_units"
}

# Records a stream's bundled-module variant. Server image only, and it carries
# its stream's patch set because patches are per core branch.
add_module_variant() {
  local stream="$1"
  local commit_hash="$2"
  local migration_edits="$3"

  server_units+=("$stream-modules")
  add_metadata "$stream-modules" "$stream-modules" "$commit_hash" "$stream" \
    "$migration_edits" "$modules" "$module_licenses" ""
}

if [[ "$stable_needs" == "true" ]]; then
  add_stream "stable" "latest,stable" "$stable_commit" "$stable_migration_edits"
  if [[ -n "$modules" ]]; then
    add_module_variant "stable" "$stable_commit" "$stable_migration_edits"
  fi
fi
if [[ "$unstable_needs" == "true" ]]; then
  add_stream "unstable" "unstable" "$unstable_commit" "$unstable_migration_edits"
  if [[ -n "$modules" ]]; then
    add_module_variant "unstable" "$unstable_commit" "$unstable_migration_edits"
  fi
fi

if ((${#server_units[@]} == 0)); then
  server_units_to_build="[]"
  database_units_to_build="[]"
  build_metadata="{}"
  any_images_to_build="false"
else
  server_units_to_build="$(jq -nc '$ARGS.positional' --args "${server_units[@]}")"
  database_units_to_build="$(jq -nc '$ARGS.positional' --args "${database_units[@]}")"
  build_metadata="$(printf '%s\n' "${metadata_entries[@]}" | jq -sc 'add')"
  any_images_to_build="true"
fi

echo "Server units to build: $server_units_to_build"
echo "Database units to build: $database_units_to_build"
echo "Build metadata: $build_metadata"

write_output any_images_to_build "$any_images_to_build"
write_output server_units_to_build "$server_units_to_build"
write_output database_units_to_build "$database_units_to_build"
write_output build_metadata "$build_metadata"
