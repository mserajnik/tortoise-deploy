#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Resolves the upstream commit of each requested source to a full commit hash.
# Sources are opt-in: each one is resolved only when its matching environment
# variables are provided. Tortoise-WoW itself is resolved here, as is every
# bundled module. Emits the resolved commit hashes as job outputs so downstream
# steps (drift check, build decision, image builds) all reference the same
# revision set even if a branch tip moves during the run.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env GH_TOKEN

resolved_any=false

if [[ -n "${TORTOISE_REPOSITORY_OWNER:-}${TORTOISE_REPOSITORY_NAME:-}${TORTOISE_REVISION:-}" ]]; then
  require_env TORTOISE_REPOSITORY_OWNER
  require_env TORTOISE_REPOSITORY_NAME
  require_env TORTOISE_REVISION

  tortoise_repository="$TORTOISE_REPOSITORY_OWNER/$TORTOISE_REPOSITORY_NAME"
  tortoise_commit_hash="$(resolve_commit_hash \
    "$TORTOISE_REPOSITORY_OWNER" "$TORTOISE_REPOSITORY_NAME" "$TORTOISE_REVISION")"
  if [[ "$resolved_any" != "true" ]]; then printf 'Resolved sources:\n'; fi
  printf '  %s@%s\n' "$tortoise_repository" "$tortoise_commit_hash"
  write_output tortoise_repository "$tortoise_repository"
  write_output tortoise_commit_hash "$tortoise_commit_hash"
  resolved_any=true
fi

if [[ -n "${TW_MOD_AUTOSCALE_REPOSITORY_OWNER:-}${TW_MOD_AUTOSCALE_REPOSITORY_NAME:-}${TW_MOD_AUTOSCALE_REVISION:-}" ]]; then
  require_env TW_MOD_AUTOSCALE_REPOSITORY_OWNER
  require_env TW_MOD_AUTOSCALE_REPOSITORY_NAME
  require_env TW_MOD_AUTOSCALE_REVISION

  tw_mod_autoscale_repository="$TW_MOD_AUTOSCALE_REPOSITORY_OWNER/$TW_MOD_AUTOSCALE_REPOSITORY_NAME"
  tw_mod_autoscale_commit_hash="$(resolve_commit_hash \
    "$TW_MOD_AUTOSCALE_REPOSITORY_OWNER" "$TW_MOD_AUTOSCALE_REPOSITORY_NAME" \
    "$TW_MOD_AUTOSCALE_REVISION")"
  if [[ "$resolved_any" != "true" ]]; then printf 'Resolved sources:\n'; fi
  printf '  %s@%s\n' "$tw_mod_autoscale_repository" "$tw_mod_autoscale_commit_hash"
  write_output tw_mod_autoscale_repository "$tw_mod_autoscale_repository"
  write_output tw_mod_autoscale_commit_hash "$tw_mod_autoscale_commit_hash"
  resolved_any=true
fi

if [[ -n "${TW_MOD_LEECH_REPOSITORY_OWNER:-}${TW_MOD_LEECH_REPOSITORY_NAME:-}${TW_MOD_LEECH_REVISION:-}" ]]; then
  require_env TW_MOD_LEECH_REPOSITORY_OWNER
  require_env TW_MOD_LEECH_REPOSITORY_NAME
  require_env TW_MOD_LEECH_REVISION

  tw_mod_leech_repository="$TW_MOD_LEECH_REPOSITORY_OWNER/$TW_MOD_LEECH_REPOSITORY_NAME"
  tw_mod_leech_commit_hash="$(resolve_commit_hash \
    "$TW_MOD_LEECH_REPOSITORY_OWNER" "$TW_MOD_LEECH_REPOSITORY_NAME" \
    "$TW_MOD_LEECH_REVISION")"
  if [[ "$resolved_any" != "true" ]]; then printf 'Resolved sources:\n'; fi
  printf '  %s@%s\n' "$tw_mod_leech_repository" "$tw_mod_leech_commit_hash"
  write_output tw_mod_leech_repository "$tw_mod_leech_repository"
  write_output tw_mod_leech_commit_hash "$tw_mod_leech_commit_hash"
  resolved_any=true
fi

if [[ -n "${MARIADB_DOCKER_REPOSITORY_OWNER:-}${MARIADB_DOCKER_REPOSITORY_NAME:-}${MARIADB_DOCKER_REVISION:-}" ]]; then
  require_env MARIADB_DOCKER_REPOSITORY_OWNER
  require_env MARIADB_DOCKER_REPOSITORY_NAME
  require_env MARIADB_DOCKER_REVISION

  mariadb_docker_repository="$MARIADB_DOCKER_REPOSITORY_OWNER/$MARIADB_DOCKER_REPOSITORY_NAME"
  mariadb_docker_commit_hash="$(resolve_commit_hash \
    "$MARIADB_DOCKER_REPOSITORY_OWNER" "$MARIADB_DOCKER_REPOSITORY_NAME" \
    "$MARIADB_DOCKER_REVISION")"
  if [[ "$resolved_any" != "true" ]]; then printf 'Resolved sources:\n'; fi
  printf '  %s@%s\n' "$mariadb_docker_repository" "$mariadb_docker_commit_hash"
  write_output mariadb_docker_repository "$mariadb_docker_repository"
  write_output mariadb_docker_commit_hash "$mariadb_docker_commit_hash"
  resolved_any=true
fi

if [[ "$resolved_any" != "true" ]]; then
  fail "No sources requested; provide environment variables for at least one source."
fi
