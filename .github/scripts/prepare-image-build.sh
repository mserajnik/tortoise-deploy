#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Produces the per build metadata consumed by the reusable build workflow:
# Dockerfile path, target architectures, image tags, build arguments, OCI
# annotations, and labels for the requested image kind and stream. A stream is
# described by its moving tag(s) (`TAG_SET`), the commit to build, the patch
# set to apply, whether to apply the customized patches, and the suffix
# appended to the commit hash tag (`-customized` for the customized stream,
# empty otherwise).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

require_env REGISTRY
require_env IMAGE_KIND
require_env ARCHITECTURES
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
tag_suffix="$(trim "${TAG_SUFFIX:-}")"
# shellcheck disable=SC2153
patch_set="$(trim "${PATCH_SET:-}")"
apply_customized="$(trim "${APPLY_CUSTOMIZED:-0}")"

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
ref_name="$image:$commit_hash$tag_suffix"

# Moving tags (`latest`, `stable`, `unstable`, `customized`) plus the immutable
# commit hash tag (suffixed for the customized stream so it never collides with
# a regular build at the same commit).
IFS=',' read -r -a moving_tags <<<"$TAG_SET"
for moving_tag in "${moving_tags[@]}"; do
  moving_tag="$(trim "$moving_tag")"
  if [[ -n "$moving_tag" ]]; then
    tags+=("$image:$moving_tag")
  fi
done
tags+=("$image:$commit_hash$tag_suffix")

if [[ "$IMAGE_KIND" == "server" ]]; then
  require_env PATCH_SET
  build_args+=(
    "TORTOISE_REVISION=$commit_hash"
    "TORTOISE_PATCHES_REPOSITORY_URL=$tortoise_patches_repository_url"
    "TORTOISE_FAIL_ON_PATCH_ERROR=1"
    "TORTOISE_PATCH_SET=$patch_set"
    "TORTOISE_APPLY_CUSTOMIZED=$apply_customized"
  )
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
  "licenses=$OCI_ANNOTATION_LICENSES"
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
