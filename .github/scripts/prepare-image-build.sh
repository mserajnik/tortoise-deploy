#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Produces the per build metadata consumed by the reusable build workflow:
# Dockerfile path, target architectures, image tags, build arguments, OCI
# annotations, and labels for the requested image kind and stream. A stream is
# described by its name (`STREAM`), its moving tag(s) (`TAG_SET`), the commit
# to build, and the patch set to apply. A bundled-module variant additionally
# carries the module set to build in (`MODULES`) and the licenses those modules
# add to the image (`MODULE_LICENSES`). `ALIAS_UNITS` names further units this
# same image is published under, which is how one database image serves a
# stream and its variants.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env REGISTRY
require_env IMAGE_KIND
require_env ARCHITECTURES
require_env STREAM
require_env TAG_SET
require_env COMMIT_HASH
require_env OCI_ANNOTATION_AUTHORS
require_env OCI_ANNOTATION_URL
require_env OCI_ANNOTATION_DOCUMENTATION
require_env OCI_ANNOTATION_SOURCE
require_env OCI_ANNOTATION_VENDOR
require_env OCI_ANNOTATION_LICENSES

timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
# shellcheck disable=SC2153
architectures="$(trim "$ARCHITECTURES")"
# shellcheck disable=SC2153
oci_annotation_authors="$(trim "$OCI_ANNOTATION_AUTHORS")"
# shellcheck disable=SC2153
oci_annotation_vendor="$(trim "$OCI_ANNOTATION_VENDOR")"
tortoise_patches_repository_url="$(trim "${TORTOISE_PATCHES_REPOSITORY_URL:-}")"
# shellcheck disable=SC2153
commit_hash="$(trim "$COMMIT_HASH")"
# shellcheck disable=SC2153
stream="$(trim "$STREAM")"
patch_set="$(trim "${PATCH_SET:-}")"
modules="$(trim "${MODULES:-}")"
alias_units="$(trim "${ALIAS_UNITS:-}")"

module_licenses="$(trim "${MODULE_LICENSES:-}")"

# Required rather than optional: a variant image whose license annotation
# silently omits its modules' licenses is worse than a failed run.
# `prepare-build-matrix.sh` guards this too, but this script is the one that
# writes the annotation. Checked after the trim, so a whitespace-only value
# cannot pass here and then empty itself.
if [[ -n "$modules" && -z "$module_licenses" ]]; then
  fail "Environment variable 'MODULE_LICENSES' is required."
fi

# shellcheck disable=SC2153
oci_annotation_licenses="$OCI_ANNOTATION_LICENSES"
if [[ -n "$modules" && -n "$module_licenses" ]]; then
  oci_annotation_licenses="$oci_annotation_licenses AND $module_licenses"
fi

declare -a tags=()
declare -a metadata_entries=()
declare -a label_lines=()
declare -a manifest_annotation_lines=()
declare -a index_annotation_lines=()
declare -a build_args=()

build_amd64="false"
build_arm64="false"
is_multi_arch="false"
title=""
description=""
base_name=""
image_name=""
dockerfile=""

case "$architectures" in
  both | "Both amd64 and arm64")
    build_amd64="true"
    build_arm64="true"
    is_multi_arch="true"
    ;;
  amd64 | "amd64 only")
    build_amd64="true"
    ;;
  arm64 | "arm64 only")
    build_arm64="true"
    ;;
  *)
    fail "Unsupported architectures value '$architectures'."
    ;;
esac

case "$IMAGE_KIND" in
  server)
    require_env IMAGE_NAME_SERVER
    require_env OCI_ANNOTATION_SERVER_TITLE
    require_env OCI_ANNOTATION_SERVER_DESCRIPTION
    require_env OCI_ANNOTATION_SERVER_BASE_NAME
    image_name="$IMAGE_NAME_SERVER"
    dockerfile="./docker/server/Dockerfile"
    title="$(trim "$OCI_ANNOTATION_SERVER_TITLE")"
    description="$(trim "$OCI_ANNOTATION_SERVER_DESCRIPTION")"
    base_name="$(trim "$OCI_ANNOTATION_SERVER_BASE_NAME")"
    ;;
  database)
    require_env IMAGE_NAME_DATABASE
    require_env OCI_ANNOTATION_DATABASE_TITLE
    require_env OCI_ANNOTATION_DATABASE_DESCRIPTION
    require_env OCI_ANNOTATION_DATABASE_BASE_NAME
    image_name="$IMAGE_NAME_DATABASE"
    dockerfile="./docker/database/Dockerfile"
    title="$(trim "$OCI_ANNOTATION_DATABASE_TITLE")"
    description="$(trim "$OCI_ANNOTATION_DATABASE_DESCRIPTION")"
    base_name="$(trim "$OCI_ANNOTATION_DATABASE_BASE_NAME")"
    ;;
  *)
    fail "Unsupported image kind '$IMAGE_KIND'."
    ;;
esac

image="$REGISTRY/$image_name"

# The unit's moving tag(s) plus the immutable commit hash tag. The latter
# carries the unit name because several units can build the same upstream
# commit and still be different images.
IFS=',' read -r -a moving_tags <<<"$TAG_SET"
for moving_tag in "${moving_tags[@]}"; do
  moving_tag="$(trim "$moving_tag")"
  if [[ -n "$moving_tag" ]]; then
    tags+=("$image:$moving_tag")
  fi
done
ref_name="$image:$stream-$commit_hash"
tags+=("$ref_name")

# Units that share this exact image get the same pair of tags, a moving one and
# a commit one, so selecting by either is uniform across the images a setup
# uses. One database image serves its stream and every bundled-module variant
# of it, because the modules add no SQL of their own; publishing the variant's
# tags here now means users never have to change the tag if that ever stops
# being true.
if [[ -n "$alias_units" ]]; then
  IFS=',' read -r -a alias_unit_names <<<"$alias_units"
  for alias_unit in "${alias_unit_names[@]}"; do
    alias_unit="$(trim "$alias_unit")"
    if [[ -n "$alias_unit" ]]; then
      tags+=("$image:$alias_unit" "$image:$alias_unit-$commit_hash")
    fi
  done
fi

if [[ "$IMAGE_KIND" == "server" ]]; then
  require_env PATCH_SET
  build_args+=(
    "TORTOISE_REVISION=$commit_hash"
    "TORTOISE_PATCHES_REPOSITORY_URL=$tortoise_patches_repository_url"
    "TORTOISE_FAIL_ON_PATCH_ERROR=1"
    "TORTOISE_PATCH_SET=$patch_set"
  )
  if [[ -n "$modules" ]]; then
    # The configuration files the repository vendors an example for. The build
    # compares this against what the modules actually install and refuses to
    # produce an image that would demand a file no example covers.
    declare -a module_configs=()
    for module_config_example in config/modules/*.conf.example; do
      if [[ -f "$module_config_example" ]]; then
        module_configs+=("$(basename "$module_config_example" .example)")
      fi
    done

    if ((${#module_configs[@]} == 0)); then
      fail "Modules were requested but 'config/modules/' vendors no configuration example."
    fi

    # Sorted in the C locale, because the build compares this against a list
    # the build container globs for itself and a string compare makes the order
    # load-bearing. Sort first: `mapfile` reports only its own status, so a
    # failing `sort` would silently read as "no module configuration files".
    module_configs_sorted="$(printf '%s\n' "${module_configs[@]}" | LC_ALL=C sort)"
    mapfile -t module_configs < <(printf '%s' "$module_configs_sorted")

    printf -v module_configs_output '%s,' "${module_configs[@]}"
    build_args+=(
      "TORTOISE_MODULES=$modules"
      "TORTOISE_MODULE_CONFIGS=${module_configs_output%,}"
    )
  fi
else
  migration_edits="$(trim "${MIGRATION_EDITS:-}")"
  build_args+=(
    "TORTOISE_REVISION=$commit_hash"
    "TORTOISE_MIGRATION_EDITS=$migration_edits"
  )
fi

metadata_entries=(
  "created=$timestamp"
  "authors=$oci_annotation_authors"
  "url=$OCI_ANNOTATION_URL"
  "documentation=$OCI_ANNOTATION_DOCUMENTATION"
  "source=$OCI_ANNOTATION_SOURCE"
  "version=$commit_hash"
  "revision=$commit_hash"
  "vendor=$oci_annotation_vendor"
  "licenses=$oci_annotation_licenses"
  "ref.name=$ref_name"
  "title=$title"
  "description=$description"
  "base.name=$base_name"
)

for entry in "${metadata_entries[@]}"; do
  key="${entry%%=*}"
  value="${entry#*=}"

  label_lines+=("org.opencontainers.image.$key=$value")
  manifest_annotation_lines+=("manifest:org.opencontainers.image.$key=$value")

  if [[ "$is_multi_arch" == "true" ]]; then
    index_annotation_lines+=("index:org.opencontainers.image.$key=$value")
  fi
done

# The bundled module set, one pair per module, so an image can be asked which
# revision of a module it carries. Labels only, and only the modules: the
# core's revision is already carried by `org.opencontainers.image.revision`,
# which leaves the modules as the one part of a variant's provenance with no
# home of its own.
if [[ -n "$modules" ]]; then
  IFS='|' read -r -a module_entries <<<"$modules"
  for module_entry in "${module_entries[@]}"; do
    module_directory="${module_entry%%=*}"
    module_source="${module_entry#*=}"
    label_lines+=(
      "io.github.mserajnik.tortoise-deploy.modules.$module_directory.repository=${module_source%@*}"
      "io.github.mserajnik.tortoise-deploy.modules.$module_directory.revision=${module_source##*@}"
    )
  done
fi

printf -v tags_output '%s,' "${tags[@]}"
tags_output="${tags_output%,}"

printf -v manifest_annotations_output '%s\n' "${manifest_annotation_lines[@]}"
manifest_annotations_output="${manifest_annotations_output%$'\n'}"

if ((${#index_annotation_lines[@]} > 0)); then
  printf -v index_annotations_output '%s\n' "${index_annotation_lines[@]}"
  index_annotations_output="${index_annotations_output%$'\n'}"
else
  index_annotations_output=""
fi

printf -v labels_output '%s\n' "${label_lines[@]}"
labels_output="${labels_output%$'\n'}"

printf -v build_args_output '%s\n' "${build_args[@]}"
build_args_output="${build_args_output%$'\n'}"

write_output image "$image"
write_output package_name "${image_name##*/}"
write_output dockerfile "$dockerfile"
write_output build_amd64 "$build_amd64"
write_output build_arm64 "$build_arm64"
write_output is_multi_arch "$is_multi_arch"
write_output tags "$tags_output"
write_multiline_output build_args "$build_args_output"
write_multiline_output manifest_annotations "$manifest_annotations_output"
write_multiline_output index_annotations "$index_annotations_output"
write_multiline_output labels "$labels_output"
