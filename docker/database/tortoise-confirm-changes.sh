#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2026 Michael Serajnik <https://github.com/mserajnik>
# SPDX-License-Identifier: AGPL-3.0-or-later

# Confirms manually applied migration edits so `update-db.sh` can continue.
# Refuses unless a halted bootstrap is actually waiting.

set -eu

# The sentinel alone is not enough. `/tmp` is in the container's writable
# layer, so a restart during a pause carries it into the next start, where the
# bootstrap only clears it once it gets that far; a confirmation issued before
# then is deleted unread. `update-db.sh` is the only thing that waits, so
# require it to be running too and refuse at once rather than after the wait.
if [[ ! -f /tmp/tortoise-changes-pending ]] ||
  ! pgrep -f '/always-initdb.d/update-db.sh' >/dev/null; then
  echo "[tortoise-deploy]: ERROR: tortoise-deploy is not currently waiting for confirmation." >&2
  exit 1
fi

# `docker compose exec` defaults to root, but the bootstrap runs as the
# database user. Match ownership to the pending sentinel so the bootstrap can
# rename the ack file out of sticky `/tmp`. A sentinel it cannot touch would
# stop the bootstrap starting at all, so the file is built under a temporary
# name and only renamed into place once it belongs to the right user; an
# interrupted run then leaves nothing behind.
acknowledged="$(mktemp /tmp/tortoise-changes-acknowledged.XXXXXX)"
trap 'rm -f "$acknowledged"' EXIT

if ! chown --reference=/tmp/tortoise-changes-pending "$acknowledged"; then
  echo "[tortoise-deploy]: ERROR: Failed to hand the confirmation to the database user. Run this command as root or as the database user." >&2
  exit 1
fi

rm -f /tmp/tortoise-changes-consumed
mv "$acknowledged" /tmp/tortoise-changes-acknowledged

# The pause renames the acknowledgement to a receipt when it takes it, so wait
# for the receipt rather than for the acknowledgement to disappear: a start
# that clears stale sentinels makes it disappear too, and reading that as
# success reports a confirmation nobody acted on.
waited=0
while [[ ! -f /tmp/tortoise-changes-consumed ]] && [[ "$waited" -lt 30 ]]; do
  sleep 1
  waited=$((waited + 1))
done

if [[ ! -f /tmp/tortoise-changes-consumed ]]; then
  rm -f /tmp/tortoise-changes-acknowledged
  echo "[tortoise-deploy]: ERROR: The confirmation was not picked up within 30 seconds. Check the container logs, then run this command again." >&2
  exit 1
fi

echo "[tortoise-deploy]: Confirmation recorded; startup will continue."
