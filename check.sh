#!/usr/bin/env bash
# Drives state.sh through the whole mount lifecycle against throwaway :local:
# mounts, once without --rc and once with it, so both the plain and the rc code
# paths are exercised without touching a real cloud mount.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="$here/state.sh"
rc_port=5599
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

mount_json() { "$state" | jq -c --arg mp "$mnt" '.mounts[] | select(.path == $mp)'; }

assert() {  # <jq filter> <expected> <label>
  local got
  got="$(mount_json | jq -r "$1")"
  [[ $got == "$2" ]] || { echo "FAIL: $3 — expected $2, got ${got:-<missing>}" >&2; exit 1; }
  echo "ok: $3"
}

start_mount() {  # extra flags for this round
  # setsid keeps it out of this shell's job table, so pkill below stays quiet.
  setsid --fork rclone mount ":local:$work/src" "$mnt" \
    --vfs-cache-mode full --vfs-write-back 300s \
    --log-file "$work/rclone.log" "$@"
  sleep 3
}

for round in plain rc; do
  echo "== $round"
  if [[ $round == rc ]]; then
    start_mount --rc --rc-addr "127.0.0.1:$rc_port" --rc-no-auth
    assert .hasRc true "rc answers"
  else
    start_mount
    assert .hasRc false "no rc"
  fi
  assert .status ok "mounted"

  # A killed mount leaves the mountpoint in /proc/self/mounts: only touching it
  # reveals the dead endpoint, which is the case the widget exists to catch.
  pkill -9 -f "rclone mount :local:$work/src" || true
  sleep 2
  assert .status stale "stale after kill"

  "$state" remount "$mnt"
  sleep 4
  assert .status ok "remounted"

  if [[ $round == rc ]]; then
    # --vfs-write-back 300s parks the write long enough to see it queued, and
    # flush has to drain it well before that timer would.
    head -c 4M /dev/urandom > "$mnt/queued.bin"
    sleep 2
    assert .queued 1 "write queued"
    "$state" flush "$mnt"
    sleep 3
    assert .queued 0 "flush drained the queue"
    [[ -f "$work/src/queued.bin" ]] || { echo "FAIL: flush did not upload" >&2; exit 1; }
    echo "ok: file landed on the remote"

    "$state" refresh "$mnt"
    echo "ok: dir cache refresh"
  fi

  "$state" unmount "$mnt"
  sleep 2
  assert .status down "unmounted"
done

echo "all checks passed"
