#!/usr/bin/env bash
# Drives state.sh through the whole mount lifecycle against a throwaway
# :local: mount, so the ok/stale/down detection and the remount action are
# exercised without touching a real cloud mount.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="$here/state.sh"
work="$(mktemp -d)"
mnt="$work/mnt"
mkdir -p "$work/src" "$mnt"
echo hello > "$work/src/a.txt"

cleanup() {
  "$state" unmount "$mnt" >/dev/null 2>&1 || true
  rm -rf "$work"
  rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-rclone/mounts/${mnt//\//%}".{cmd,meta}
}
trap cleanup EXIT

status_now() { "$state" | jq -r --arg mp "$mnt" '.mounts[] | select(.path == $mp) | .status'; }

assert_status() {
  local want="$1" got
  got="$(status_now)"
  [[ $got == "$want" ]] || { echo "FAIL: expected $want, got ${got:-<missing>}" >&2; exit 1; }
  echo "ok: $want"
}

rclone mount ":local:$work/src" "$mnt" --daemon --log-file "$work/rclone.log"
sleep 3
assert_status ok

# A killed mount leaves the mountpoint in /proc/self/mounts: only touching it
# reveals the dead endpoint, which is the case the widget exists to catch.
pkill -9 -f "rclone mount :local:$work/src" || true
sleep 2
assert_status stale

"$state" remount "$mnt"
sleep 4
assert_status ok

"$state" unmount "$mnt"
sleep 2
assert_status down

echo "all checks passed"
