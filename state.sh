#!/usr/bin/env bash
# Data source for the io.github.dretureta.rclone bar widget.
#
#   state.sh              print one JSON object describing every rclone mount
#   state.sh unmount <mp> lazily unmount <mp>
#   state.sh remount <mp> unmount <mp>, then re-run the command that created it
#
# Everything slow (rclone about, du of the VFS cache) is answered from a cache
# file and refreshed in a detached background job, so printing state never
# blocks the bar.
set -uo pipefail

readonly cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-rclone"
readonly mounts_dir="$cache_dir/mounts"
readonly about_ttl=3600     # `rclone about` burns a provider API call
readonly cache_size_ttl=900 # du over a 110G VFS cache is not free
readonly vfs_dir="${XDG_CACHE_HOME:-$HOME/.cache}/rclone/vfs"

mkdir -p "$mounts_dir"

# A mount seen once is remembered so it can be reported as down later; drop
# entries nothing has refreshed for a week so one-off mounts do not pile up.
find "$mounts_dir" -mindepth 1 -mtime +7 -delete 2>/dev/null

# A mountpoint doubles as a cache key, so flatten it into one filename.
key_for() { printf '%s' "${1//\//%}"; }

age_of() {
  local f="$1" now mtime
  [[ -f "$f" ]] || { echo 999999999; return; }
  now=$(printf '%(%s)T' -1)
  mtime=$(stat -c %Y -- "$f" 2>/dev/null || echo 0)
  echo $((now - mtime))
}

# Run a refresh in the background exactly once: the lock dir doubles as the
# "already refreshing" flag, so a 10s bar tick cannot pile up 60 du processes.
refresh_bg() {
  local out="$1"; shift
  local lock="$out.lock"
  mkdir "$lock" 2>/dev/null || return 0
  setsid --fork bash -c '
    out="$1"; lock="$2"; shift 2
    if "$@" > "$out.tmp" 2>/dev/null && [[ -s "$out.tmp" ]]; then mv -f "$out.tmp" "$out"; else rm -f "$out.tmp"; fi
    rmdir "$lock"
  ' _ "$out" "$lock" "$@" >/dev/null 2>&1 &
}

# ---------------------------------------------------------------- actions

unmount_tool() { command -v fusermount3 || command -v fusermount; }

do_unmount() {
  local mp="$1" tool
  tool=$(unmount_tool) || exit 1
  "$tool" -uz -- "$mp"
}

do_remount() {
  local mp="$1" saved argv
  saved="$mounts_dir/$(key_for "$mp").cmd"
  [[ -f "$saved" ]] || { echo "no saved command for $mp" >&2; exit 1; }
  do_unmount "$mp" 2>/dev/null
  mapfile -d '' -t argv < "$saved"
  [[ ${#argv[@]} -gt 0 ]] || exit 1
  setsid --fork "${argv[@]}" >/dev/null 2>&1 &
}

case "${1:-}" in
  unmount) do_unmount "${2:?mountpoint required}"; exit ;;
  remount) do_remount "${2:?mountpoint required}"; exit ;;
  "") ;;
  *) echo "unknown command: $1" >&2; exit 64 ;;
esac

# ---------------------------------------------------------------- discovery

# Mountpoints the kernel currently has as fuse.rclone.
declare -A is_mounted=()
while read -r _ mp fstype _; do
  [[ $fstype == fuse.rclone ]] || continue
  printf -v mp '%b' "${mp//\\/\\\\x}"   # /proc escapes spaces as \040
  is_mounted["$mp"]=1
done < /proc/self/mounts

# Live `rclone mount` processes, with the exact argv saved so a dead mount can
# be brought back later — once the process is gone, that argv is unrecoverable.
declare -A pid_of=() remote_of=() log_of=()
for cmdline in /proc/[0-9]*/cmdline; do
  pid=${cmdline#/proc/}; pid=${pid%/cmdline}
  mapfile -d '' -t argv 2>/dev/null < "$cmdline" || continue
  [[ ${#argv[@]} -ge 4 && ${argv[0]##*/} == rclone && ${argv[1]} == mount ]] || continue

  remote=${argv[2]} mp=${argv[3]} log=""
  for ((i = 4; i < ${#argv[@]}; i++)); do
    case ${argv[i]} in
      --log-file=*) log=${argv[i]#--log-file=} ;;
      --log-file) log=${argv[i + 1]:-} ;;
    esac
  done

  pid_of["$mp"]=$pid remote_of["$mp"]=$remote log_of["$mp"]=$log
  key=$(key_for "$mp")
  printf '%s\0' "${argv[@]}" > "$mounts_dir/$key.cmd"
  printf '%s\n%s\n' "$remote" "$log" > "$mounts_dir/$key.meta"
done

# Anything ever seen stays in the union, so a mount that died is reported as
# down instead of silently vanishing from the panel.
declare -A seen=()
for mp in "${!is_mounted[@]}" "${!pid_of[@]}"; do seen["$mp"]=1; done
for meta in "$mounts_dir"/*.meta; do
  [[ -f $meta ]] || continue
  key=${meta##*/}; key=${key%.meta}
  seen["${key//%//}"]=1
done

# ---------------------------------------------------------------- per mount

today=$(printf '%(%Y/%m/%d)T' -1)
rows=()

for mp in "${!seen[@]}"; do
  key=$(key_for "$mp")
  remote=${remote_of[$mp]:-} log=${log_of[$mp]:-}
  if [[ -z $remote && -f "$mounts_dir/$key.meta" ]]; then
    { read -r remote; read -r log; } < "$mounts_dir/$key.meta"
  fi

  pid=${pid_of[$mp]:-0}
  if [[ -n ${is_mounted[$mp]:-} ]]; then
    # Mounted in the kernel is not the same as usable: a dead FUSE endpoint
    # stays in /proc/self/mounts and only fails when something touches it.
    if timeout 2 stat -c %i -- "$mp" >/dev/null 2>&1; then status=ok; else status=stale; fi
  elif ((pid > 0)); then
    status=mounting
  else
    status=down
  fi

  errors=0 last_error=""
  if [[ -n $log && -r $log ]]; then
    mapfile -t error_lines < <(tail -n 2000 -- "$log" 2>/dev/null | grep -F " ERROR " | grep -F "$today")
    errors=${#error_lines[@]}
    ((errors > 0)) && last_error=${error_lines[-1]}
  fi

  about="{}"
  if [[ -n $remote ]]; then
    about_file="$cache_dir/about-$(key_for "$remote").json"
    (($(age_of "$about_file") > about_ttl)) &&
      refresh_bg "$about_file" timeout 30 rclone about "$remote" --json
    [[ -s $about_file ]] && about=$(<"$about_file")
  fi

  rows+=("$(jq -cn \
    --arg mp "$mp" --arg remote "$remote" --arg status "$status" --arg log "$log" \
    --arg lastError "$last_error" --argjson pid "$pid" --argjson errors "$errors" \
    --argjson about "$about" \
    --argjson canRemount "$([[ -f "$mounts_dir/$key.cmd" ]] && echo true || echo false)" \
    '{path: $mp, remote: $remote, status: $status, pid: $pid, log: $log,
      errors: $errors, lastError: $lastError, canRemount: $canRemount,
      total: ($about.total // null), used: ($about.used // null), free: ($about.free // null)}')")
done

# ---------------------------------------------------------------- cache size

cache_file="$cache_dir/vfs-size"
if [[ -d $vfs_dir ]] && (($(age_of "$cache_file") > cache_size_ttl)); then
  refresh_bg "$cache_file" bash -c 'du -sxb -- "$1" 2>/dev/null | cut -f1' _ "$vfs_dir"
fi
vfs_bytes=$(cat "$cache_file" 2>/dev/null)
[[ $vfs_bytes =~ ^[0-9]+$ ]] || vfs_bytes=-1

printf '%s\n' "${rows[@]:-}" | jq -sc \
  --argjson vfsBytes "$vfs_bytes" \
  'map(select(. != null)) | sort_by(.remote) |
   {mounts: .,
    total: length,
    ok: (map(select(.status == "ok")) | length),
    problems: (map(select(.status == "down" or .status == "stale")) | length),
    errors: (map(.errors) | add // 0),
    vfsBytes: $vfsBytes}'
