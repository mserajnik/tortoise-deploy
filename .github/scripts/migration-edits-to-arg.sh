#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Flattens a unit's entry in `.github/migration-edit-state.json` to the
# `TORTOISE_MIGRATION_EDITS` build argument: pipe-separated
# `<target>:<source>@<commit-hash>[,<source>@<commit-hash>]...` entries for
# each of `world` and `character`, with an empty source list where the unit has
# no recorded edit for that target. The build handles one unit at a time. This
# script takes a unit alongside the state file.
#
# A target gets one entry per source its edits came from, because migrations
# for one target can come from several sources. Each entry keeps its source,
# because the container prints the commit in its messages, and a module's
# commit belongs to the module's repository. Sorting the sources makes one
# state always render the same argument, which keeps a rebuild from changing
# the image for no reason.
#
# Where the database image can re-create the target, the record is a bare
# object. Where the operator has to fix it by hand, the record is a list. The
# argument keeps only the commit hash the container-side parser reads. Both
# forms reduce to that. In a list, index 0 is the newest edit.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR
source "$script_dir/helpers.sh"

if [[ "$#" -ne 2 ]]; then
  fail "Usage: $0 <state-file> <unit>"
fi

state_file="$1"
unit="$2"

# A state file jq cannot read as an object would yield an empty token, which
# reads as "this unit has no recorded edit." `version` tells this shape apart
# from the flat one that preceded it, whose entries this filter would silently
# render as empty.
if ! jq -e '
  type == "object"
  and .version == 1
  and .source_kind == "repository"
  and (.streams | type) == "object"
  and all(.streams[]; type == "object"
      and (keys_unsorted - ["world", "character"]) == []
      and all(.[]; type == "object"
          and (keys_unsorted - ["core", "tortoisebots"]) == []
          and all(.[];
                (type == "object" and has("commit"))
                or (type == "array" and length > 0
                    and all(.[]; type == "object" and has("commit"))))))
  and all(.. | objects | select(has("commit")) | .commit;
          type == "string" and length == 40 and test("^[0-9a-f]{40}$"))
' "$state_file" >/dev/null; then
  fail "State file '$state_file' is missing, is not a version 1 repository-sourced state object with 'world' and 'character' targets and 'core' and 'tortoisebots' sources, or holds a malformed commit hash."
fi

# An unrecognized unit indexes to `null`, which renders the same empty token
# for every target and is indistinguishable from "no recorded edit."
if ! jq -e --arg unit "$unit" '.streams | has($unit)' "$state_file" >/dev/null; then
  fail "State file '$state_file' has no entry for unit '$unit'."
fi

jq -r --arg unit "$unit" '
  ["world", "character"] as $order
  | .streams[$unit] as $targets
  | [$order[] as $db
     | [(($targets[$db] // {}) | to_entries | sort_by(.key))[]
        | .key as $source
        | (if (.value | type) == "array"
           then .value[0].commit
           else .value.commit end) as $commit
        | "\($source)@\($commit)"]
       | join(",") as $sources
     | "\($db):\($sources)"]
  | join("|")
' "$state_file"
