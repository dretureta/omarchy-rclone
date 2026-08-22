#!/usr/bin/env bash
# Drives state.sh through the whole mount lifecycle against throwaway :local:
# mounts, once without --rc and once with it, so both the plain and the rc code
# paths are exercised without touching a real cloud mount.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="$here/state.sh"
rc_port=5599
rc_sock="${XDG_RUNTIME_DIR:-/tmp}/omarchy-rclone-check.sock"
work="$(mktemp -d)"
mnt="$work/mnt"
mkdir -p "$work/src" "$mnt"
echo hello > "$work/src/a.txt"

cleanup() {
  "$state" unmount "$mnt" >/dev/null 2>&1 || true
  rm -rf "$work"
  rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-rclone/mounts/${mnt//\//%}".{cmd,meta,status}
  rm -f "$rc_sock"
}
trap cleanup EXIT

# Every icon in the panel is a private-use codepoint, and a missing one does not
# fail loudly: fontconfig substitutes another font and the button quietly
# renders somebody else's icon. A codepoint that several fonts claim is just as
# bad, because the shell may not resolve it the way your test render did — that
# is how U+F052, eject in a Nerd Font, came out as a dot grid from Font Awesome.
check_glyphs() {
  local bad=0 char cp families nerd others f
  while read -r char; do
    printf -v cp '%x' "'$char"
    mapfile -t families < <(fc-list ":charset=$cp" family | tr ',' '\n' | LC_ALL=C sort -u)
    nerd=() others=()
    for f in "${families[@]}"; do
      [[ -n $f ]] || continue
      if [[ $f == *"Nerd Font"* || $f == *" NF" ]]; then nerd+=("$f"); else others+=("$f"); fi
    done
    if ((${#nerd[@]} == 0)); then
      echo "FAIL: U+${cp^^} ($char) is in no Nerd Font here" >&2; bad=1
    elif ((${#others[@]})); then
      echo "FAIL: U+${cp^^} ($char) is also claimed by ${others[*]}, so fontconfig may pick that one" >&2; bad=1
    else
      echo "ok: U+${cp^^} $char"
    fi
  # LC_ALL=C on the sort because under a UTF-8 locale these codepoints collate
  # as equal and `sort -u` would keep exactly one of them.
  done < <(grep -ohP '[\x{E000}-\x{F8FF}\x{F0000}-\x{FFFFD}]' "$here"/*.qml | LC_ALL=C sort -u)
  return $bad
}

echo "== glyphs"
check_glyphs
[[ ${1:-} == glyphs ]] && exit 0

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

# Both rc dial modes are covered: a unix socket is what the systemd unit uses,
# a host:port is what a hand-rolled `rclone mount --rc` usually has.
for round in plain rc-tcp rc-socket; do
  echo "== $round"
  case $round in
    rc-tcp)    start_mount --rc --rc-addr "127.0.0.1:$rc_port" --rc-no-auth ;;
    rc-socket) rm -f "$rc_sock"; start_mount --rc --rc-addr "unix://$rc_sock" --rc-no-auth ;;
    *)         start_mount ;;
  esac
  [[ $round == plain ]] && assert .hasRc false "no rc" || assert .hasRc true "rc answers"
  assert .status ok "mounted"

  # A killed mount leaves the mountpoint in /proc/self/mounts: only touching it
  # reveals the dead endpoint, which is the case the widget exists to catch.
  pkill -9 -f "rclone mount :local:$work/src" || true
  sleep 2
  assert .status stale "stale after kill"

  "$state" remount "$mnt"
  sleep 4
  assert .status ok "remounted"

  if [[ $round != plain ]]; then
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
