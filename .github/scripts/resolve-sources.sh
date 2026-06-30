#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Resolves the upstream commit of each requested source to a full commit hash.
# Sources are opt-in: each one is resolved only when its matching environment
# variables are provided. Tortoise-WoW is built from two branches (`main` for
# `stable`, `1181dev` for `unstable`), so both are resolved here. Emits the
# resolved commit hashes as job outputs so downstream steps (drift check, build
# decision, image builds) all reference the same revision set even if a branch
# tip moves during the run.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env GH_TOKEN

resolved_any=false

if [[ -n "${TORTOISE_REPOSITORY_OWNER:-}${TORTOISE_REPOSITORY_NAME:-}${TORTOISE_STABLE_REVISION:-}${TORTOISE_UNSTABLE_REVISION:-}" ]]; then
  require_env TORTOISE_REPOSITORY_OWNER
  require_env TORTOISE_REPOSITORY_NAME
  require_env TORTOISE_STABLE_REVISION
  require_env TORTOISE_UNSTABLE_REVISION

  tortoise_repository="$TORTOISE_REPOSITORY_OWNER/$TORTOISE_REPOSITORY_NAME"
  tortoise_stable_commit_hash="$(resolve_commit_hash \
    "$TORTOISE_REPOSITORY_OWNER" "$TORTOISE_REPOSITORY_NAME" "$TORTOISE_STABLE_REVISION")"
  tortoise_unstable_commit_hash="$(resolve_commit_hash \
    "$TORTOISE_REPOSITORY_OWNER" "$TORTOISE_REPOSITORY_NAME" "$TORTOISE_UNSTABLE_REVISION")"
  if [[ "$resolved_any" != "true" ]]; then printf 'Resolved sources:\n'; fi
  printf '  %s@%s (main)\n' "$tortoise_repository" "$tortoise_stable_commit_hash"
  printf '  %s@%s (1181dev)\n' "$tortoise_repository" "$tortoise_unstable_commit_hash"
  write_output tortoise_repository "$tortoise_repository"
  write_output tortoise_stable_commit_hash "$tortoise_stable_commit_hash"
  write_output tortoise_unstable_commit_hash "$tortoise_unstable_commit_hash"
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
