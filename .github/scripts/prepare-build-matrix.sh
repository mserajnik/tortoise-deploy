#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Decides whether the default workflow builds anything this run and emits the
# build units consumed by the server and database build jobs. The build is
# skipped when the `base` moving tag already points at the current commit,
# unless the run is a scheduled Monday rebuild or a manual force rebuild.
# Records any migration edit in the state file and bakes it into each build's
# `migration_edits` so the database image can act on it.
#
# A unit is one build leg. `base` is the core on its own; when modules are
# requested, a `modules` unit carrying the bundled module set is added. A
# variant unit is built exactly when `base` is, so there is no second build
# decision. It produces a server image only and shares the `base` database
# image, which keeps it out of the state file. The server job therefore builds
# every unit, and the database job builds only the units that need a database
# image of their own.

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
require_env TORTOISE_COMMIT_HASH
require_env STATE_FILE

# This anchor is the Tortoise-WoW commit that the last image published before
# the `base` rename was built from. Every run that finds a prior build takes
# the scan floor from the registry; this anchor supplies it when none is found,
# as on the first run after the rename. Everything up to this commit was
# already scanned while the unit was called `stable` and is recorded in the
# state file, so that run picks up exactly the commits that arrived since.
TORTOISE_CUTOFF="5fafe43b576116c3aecde435c41c87a47864f943"

tortoise_commit="$(trim "$TORTOISE_COMMIT_HASH")"
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
  local unit="$3"

  LAST_BUILT_COMMIT_HASH="$last_built" \
    CURRENT_COMMIT_HASH="$current" \
    UNIT="$unit" \
    STATE_FILE="$STATE_FILE" \
    "$script_dir/compute-migration-edits.sh"
}

# shellcheck disable=SC2153
last_built="$(last_built_commit_for_unit "$PACKAGE_OWNER" "$PACKAGE_NAME" "base")"

# The build decision below uses the resolved value as it is; an empty string
# forces a rebuild. The migration-edit scan instead needs a commit to walk
# from, so it falls back to the cutoff anchor.
scan_floor="$last_built"
if [[ -z "$scan_floor" ]]; then
  echo "No prior package version with a commit hash tag found for unit 'base'; falling back to migration edit cutoff."
  scan_floor="$TORTOISE_CUTOFF"
fi

needs_build="false"
if [[ "$always_build" == "true" || "$last_built" != "$tortoise_commit" ]]; then
  needs_build="true"
fi

# Record any migration edit before building.
if [[ "$needs_build" == "true" ]]; then
  run_compute "$scan_floor" "$tortoise_commit" "base"
fi

migration_edits="$("$script_dir/migration-edits-to-arg.sh" "$STATE_FILE" "base")"

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

# Records the `base` unit: one server image and one database image from the
# same commit. The database image is also published under the tags of every
# variant that shares it; only the server job builds a variant of its own.
add_base() {
  local commit_hash="$1"
  local migration_edits="$2"
  local database_alias_units=""

  if [[ -n "$modules" ]]; then
    database_alias_units="modules"
  fi

  server_units+=("base")
  database_units+=("base")
  add_metadata "base" "latest,base" "$commit_hash" "base" "$migration_edits" \
    "" "" "$database_alias_units"
}

# Records a bundled-module variant. The variant gets a server image only and
# shares the `base` database image. It carries the `base` patch set, which is
# the patch set for the core it is built from.
add_module_variant() {
  local unit="$1"
  local commit_hash="$2"
  local migration_edits="$3"

  server_units+=("$unit")
  add_metadata "$unit" "$unit" "$commit_hash" "base" \
    "$migration_edits" "$modules" "$module_licenses" ""
}

if [[ "$needs_build" == "true" ]]; then
  add_base "$tortoise_commit" "$migration_edits"
  if [[ -n "$modules" ]]; then
    add_module_variant "modules" "$tortoise_commit" "$migration_edits"
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
