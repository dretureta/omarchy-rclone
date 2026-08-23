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

# An empty config of our own: these mounts are all on-the-fly :local: remotes,
# and reading the real rclone.conf would stop to ask for its password on any
# machine where it is encrypted.
export RCLONE_CONFIG="$work/rclone.conf"
: > "$RCLONE_CONFIG"

cleanup() {
  "$state" unmount "$mnt" >/dev/null 2>&1 || true
  rm -rf "$work"
  rm -f "${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-rclone/mounts/${mnt//\//%}".{cmd,meta,status}
  rm -f "$rc_sock"
  systemctl --user stop omarchy-rclone-check.service >/dev/null 2>&1 || true
  rm -f "$HOME/.config/systemd/user/omarchy-rclone-check.service"
  rm -f "${XDG_RUNTIME_DIR:-/tmp}/omarchy-rclone-check-unit.sock"
  systemctl --user daemon-reload >/dev/null 2>&1 || true
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

# The systemd path has its own failure mode, and it is the one that bit for
# real: a unit that failed enough times is rate limited, and `systemctl
# restart` refuses with "Start request repeated too quickly" until the failure
# is reset. The remount button did nothing at exactly the wrong moment.
check_systemd() {
  local unit=omarchy-rclone-check.service
  local unit_file="$HOME/.config/systemd/user/$unit"
  local sock="${XDG_RUNTIME_DIR:-/tmp}/omarchy-rclone-check-unit.sock"
  local tries=0

  systemctl --user show-environment >/dev/null 2>&1 || { echo "skip: no user systemd"; return 0; }

  mkdir -p "$(dirname "$unit_file")"
  cat > "$unit_file" <<UNIT
[Unit]
Description=omarchy-rclone check mount
StartLimitBurst=2
StartLimitIntervalSec=60

[Service]
Type=notify
Environment=RCLONE_CONFIG=$work/rclone.conf
ExecStartPre=-/usr/bin/rm -f $sock
ExecStart=/usr/bin/rclone mount :local:$work/src $mnt --vfs-cache-mode full \
  --rc --rc-addr unix://$sock --rc-no-auth --log-file $work/rclone.log
Restart=on-failure
RestartSec=1
UNIT
  systemctl --user daemon-reload

  systemctl --user start "$unit"
  sleep 2
  assert .unit "$unit" "unit read from the cgroup"
  assert .status ok "unit mounted"

  systemctl --user stop "$unit"
  sleep 2
  # rclone refuses a non-empty mountpoint, which is how the real one failed.
  : > "$mnt/intruder"
  while [[ $(systemctl --user show "$unit" -p Result --value) != start-limit-hit ]]; do
    ((++tries > 6)) && { echo "FAIL: could not drive the unit into its start limit" >&2; return 1; }
    systemctl --user start "$unit" >/dev/null 2>&1 || true
    sleep 2
  done
  echo "ok: unit is rate limited after repeated failures"

  rm -f "$mnt/intruder"
  "$state" remount "$mnt"
  sleep 4
  [[ $(systemctl --user is-active "$unit") == active ]] ||
    { echo "FAIL: remount did not recover a rate-limited unit" >&2; return 1; }
  assert .status ok "remount cleared the start limit"

  systemctl --user stop "$unit" 2>/dev/null || true
  rm -f "$unit_file" "$sock"
  systemctl --user daemon-reload
}

echo "== systemd"
check_systemd

echo "all checks passed"
