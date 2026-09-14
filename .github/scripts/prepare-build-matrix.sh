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
# A unit is one build leg. `base` is the core on its own. A configured module
# set becomes a `modules` unit, and adding TortoiseBots to that set produces a
# `modules-bots` unit. Each variant builds exactly when `base` does, and no
# second build decision exists.
#
# A variant that contributes no SQL of its own shares the `base` database
# image, which keeps it out of the state file. `modules` works that way. A
# variant whose modules contribute migrations needs a database image of its
# own, because an edit found in a module belongs to a deployment running it
# alone. The server job builds every unit, and the database job builds the
# units that need a database image of their own.

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

# The same anchor for TortoiseBots, used until a `modules-bots` image exists to
# read a revision from. An edit to a module migration before that first image
# is harmless, because every existing database predates the module's tables.
TW_MOD_TORTOISEBOTS_CUTOFF="68f820c7aa3ee869655883d23b76a2d9de991d65"

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

# One walk per source. `units` is a comma-separated list, because the core's
# window is the same for every unit built from the same commit and walking it
# once per unit would clone and scan identical commits for an identical answer.
run_compute() {
  local last_built="$1"
  local current="$2"
  local source_name="$3"
  local source_repository="$4"
  local units="$5"

  LAST_BUILT_COMMIT_HASH="$last_built" \
    CURRENT_COMMIT_HASH="$current" \
    SOURCE="$source_name" \
    SOURCE_REPOSITORY_OWNER="${source_repository%%/*}" \
    SOURCE_REPOSITORY_NAME="${source_repository##*/}" \
    UNITS="$units" \
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

# The bundled module set, packed into the single `TORTOISE_MODULES` build
# argument the server Dockerfile takes: `<directory>=<url>@<revision>` entries
# separated by `|`. The directory name is the module repository's name, because
# that is the name the generated module loader derives its symbol from.
module_entry() {
  local repository="$1"
  local commit_hash="$2"

  printf '%s=https://github.com/%s.git@%s' \
    "${repository##*/}" "$repository" "$commit_hash"
}

# Each variant also lists the configuration examples the repository vendors for
# its modules, because the build compares that list against what the modules
# installed. Each module contributes its own entries, and a module's own name
# does not yield the file name, because TortoiseBots installs
# `tortoise_bots.conf`.
#
# An entry is a path relative to the configuration directory, because where a
# file goes is part of what has to match. Most module templates go under
# `modules/`, and a module may install one beside `mangosd.conf`, as
# TortoiseBots does with `aiplayerbot.conf`.
declare -a module_entries=()
declare -a module_config_entries=()

if [[ -n "${TW_MOD_AUTOSCALE_REPOSITORY:-}${TW_MOD_AUTOSCALE_COMMIT_HASH:-}" ]]; then
  require_env TW_MOD_AUTOSCALE_REPOSITORY
  require_env TW_MOD_AUTOSCALE_COMMIT_HASH

  module_entries+=("$(module_entry \
    "$TW_MOD_AUTOSCALE_REPOSITORY" "$TW_MOD_AUTOSCALE_COMMIT_HASH")")
  module_config_entries+=(modules/tw-mod-autoscale.conf)
fi
if [[ -n "${TW_MOD_LEECH_REPOSITORY:-}${TW_MOD_LEECH_COMMIT_HASH:-}" ]]; then
  require_env TW_MOD_LEECH_REPOSITORY
  require_env TW_MOD_LEECH_COMMIT_HASH

  module_entries+=("$(module_entry \
    "$TW_MOD_LEECH_REPOSITORY" "$TW_MOD_LEECH_COMMIT_HASH")")
  module_config_entries+=(modules/tw-mod-leech.conf)
fi

# `modules-bots` is the `modules` set plus TortoiseBots, which makes it a
# superset of `modules` by construction.
declare -a bots_module_entries=("${module_entries[@]}")
declare -a bots_module_config_entries=("${module_config_entries[@]}")
bots_build_packages=""
bots_module_sql_modules=""
tortoisebots_repository=""
tortoisebots_commit=""

if [[ -n "${TW_MOD_TORTOISEBOTS_REPOSITORY:-}${TW_MOD_TORTOISEBOTS_COMMIT_HASH:-}" ]]; then
  require_env TW_MOD_TORTOISEBOTS_REPOSITORY
  require_env TW_MOD_TORTOISEBOTS_COMMIT_HASH

  tortoisebots_repository="$(trim "$TW_MOD_TORTOISEBOTS_REPOSITORY")"
  tortoisebots_commit="$(trim "$TW_MOD_TORTOISEBOTS_COMMIT_HASH")"

  bots_module_entries+=("$(module_entry \
    "$tortoisebots_repository" "$tortoisebots_commit")")
  # `aiplayerbot.conf` installs beside `mangosd.conf`, and the module disables
  # itself when that file is absent. The list below covers it alongside the
  # module's own template.
  bots_module_config_entries+=(aiplayerbot.conf modules/tortoise_bots.conf)
  # TortoiseBots includes six Boost headers directly, and its build declares
  # neither a `find_package` nor a link rule for them.
  bots_build_packages="libboost-dev libboost-filesystem-dev"
  # The modules whose SQL this variant's build may apply. The directory name
  # comes from the same expression the module entry's does, so the two cannot
  # name different directories. Every other variant leaves the list empty, and
  # the build refuses any module that has SQL in its tree and is absent here.
  bots_module_sql_modules="${tortoisebots_repository##*/}"
fi

# Packs an array of module entries into the `|`-separated build argument.
pack_modules() {
  local packed=""

  if (($# > 0)); then
    printf -v packed '%s|' "$@"
  fi

  printf '%s' "${packed%|}"
}

# Packs an array of configuration file entries into the `,`-separated build
# argument, sorted in the C locale because the build compares it against a list
# it globs for itself, and a string compare makes the order matter.
pack_module_configs() {
  if (($# == 0)); then
    return
  fi

  printf '%s\n' "$@" | LC_ALL=C sort | paste -sd, -
}

modules="$(pack_modules "${module_entries[@]}")"
module_configs="$(pack_module_configs "${module_config_entries[@]}")"
bots_modules="$(pack_modules "${bots_module_entries[@]}")"
bots_module_configs="$(pack_module_configs \
  "${bots_module_config_entries[@]}")"

module_licenses=""
bots_module_licenses=""
if [[ -n "$modules" ]]; then
  # Required rather than optional: a variant image whose license annotation
  # silently omits its modules' licenses is worse than a failed run. Checked
  # after the trim, so a whitespace-only value cannot pass here and then empty
  # itself further down the workflow.
  module_licenses="$(trim "${MODULE_LICENSES:-}")"
  if [[ -z "$module_licenses" ]]; then
    fail "Environment variable 'MODULE_LICENSES' is required."
  fi
  echo "Bundled module set: $modules"
fi
if [[ "$bots_modules" != "$modules" ]]; then
  # `modules-bots` has a license the curated set lacks. It needs its own value
  # for the same reason.
  bots_module_licenses="$(trim "${BOTS_MODULE_LICENSES:-}")"
  if [[ -z "$bots_module_licenses" ]]; then
    fail "Environment variable 'BOTS_MODULE_LICENSES' is required."
  fi
  echo "Bots module set: $bots_modules"
fi

# Record any migration edit before building. Every unit built from the core's
# commit takes the core's edits, so one walk covers them all. The module's
# edits go to the variant that bundles it.
if [[ "$needs_build" == "true" ]]; then
  core_units="base"
  if [[ "$bots_modules" != "$modules" ]]; then
    core_units="base,modules-bots"
  fi

  run_compute "$scan_floor" "$tortoise_commit" core \
    "$TORTOISE_REPOSITORY_OWNER/$TORTOISE_REPOSITORY_NAME" "$core_units"

  if [[ "$bots_modules" != "$modules" ]]; then
    require_env REGISTRY
    require_env PACKAGE_NAME_SERVER

    # A tag contains the core's commit alone. The module's floor comes from the
    # label on the previous `modules-bots` server image, where the module is.
    tortoisebots_scan_floor="$(last_built_module_commit_for_unit \
      "$REGISTRY" "$PACKAGE_OWNER" "$PACKAGE_NAME_SERVER" \
      modules-bots "${tortoisebots_repository##*/}")"

    if [[ -z "$tortoisebots_scan_floor" ]]; then
      echo "No prior bots image records a TortoiseBots revision; falling back to migration edit cutoff."
      tortoisebots_scan_floor="$TW_MOD_TORTOISEBOTS_CUTOFF"
    fi

    run_compute "$tortoisebots_scan_floor" "$tortoisebots_commit" \
      tortoisebots "$tortoisebots_repository" modules-bots
  fi
fi

migration_edits="$("$script_dir/migration-edits-to-arg.sh" "$STATE_FILE" "base")"

# `modules-bots` renders its own wire value. An edit recorded for one unit says
# nothing about the other, and a `base` user must never get a remedy for a
# table that exists only where TortoiseBots runs.
bots_migration_edits=""
if [[ "$bots_modules" != "$modules" ]]; then
  bots_migration_edits="$("$script_dir/migration-edits-to-arg.sh" \
    "$STATE_FILE" "modules-bots")"
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
    --arg module_configs "$7" \
    --arg module_licenses "$8" \
    --arg module_build_packages "$9" \
    --arg module_sql_modules "${10}" \
    --arg database_alias_units "${11}" \
    '{
       ($unit): {
         tag_set: $tag_set,
         commit_hash: $commit_hash,
         patch_set: $patch_set,
         migration_edits: $migration_edits,
         modules: $modules,
         module_configs: $module_configs,
         module_licenses: $module_licenses,
         module_build_packages: $module_build_packages,
         module_sql_modules: $module_sql_modules,
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
    "" "" "" "" "" "$database_alias_units"
}

# Records a bundled-module variant that shares the `base` database image. Its
# `module_sql_modules` is empty. Its build refuses a module with SQL anywhere
# in its tree, and the databases it needs remain the ones `base` already
# creates. It takes the `base` patch set, which is the patch set for the core
# it builds from.
add_module_variant() {
  local unit="$1"
  local commit_hash="$2"
  local migration_edits="$3"

  server_units+=("$unit")
  add_metadata "$unit" "$unit" "$commit_hash" "base" "$migration_edits" \
    "$modules" "$module_configs" "$module_licenses" "" "" ""
}

# Records `modules-bots`. Unlike `modules` it builds a database image of its
# own, because TortoiseBots provides migrations.
add_bots_variant() {
  local unit="$1"
  local commit_hash="$2"
  local migration_edits="$3"

  server_units+=("$unit")
  database_units+=("$unit")
  add_metadata "$unit" "$unit" "$commit_hash" "base" "$migration_edits" \
    "$bots_modules" "$bots_module_configs" \
    "$bots_module_licenses" "$bots_build_packages" \
    "$bots_module_sql_modules" ""
}

if [[ "$needs_build" == "true" ]]; then
  add_base "$tortoise_commit" "$migration_edits"
  if [[ -n "$modules" ]]; then
    add_module_variant "modules" "$tortoise_commit" "$migration_edits"
  fi
  if [[ "$bots_modules" != "$modules" ]]; then
    add_bots_variant "modules-bots" "$tortoise_commit" \
      "$bots_migration_edits"
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
