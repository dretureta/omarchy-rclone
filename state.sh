#!/usr/bin/env bash
# Data source for the io.github.dretureta.rclone bar widget.
#
#   state.sh              print one JSON object describing every rclone mount
#   state.sh unmount <mp> lazily unmount <mp>
#   state.sh remount <mp> unmount <mp>, then re-run the command that created it
#   state.sh refresh <mp> re-read the dir cache (needs --rc)
#   state.sh flush <mp>   upload everything queued right now (needs --rc)
#
# Mounts started with --rc answer over HTTP on localhost, which is where the
# live numbers come from. Without it the widget still reports mount health, it
# just cannot see speed, queue, or cache usage.
set -uo pipefail

readonly cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/omarchy-rclone"
readonly mounts_dir="$cache_dir/mounts"
readonly about_ttl=3600     # `about` is a provider API call even over rc
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

# rclone's remote control. curl rather than `rclone rc`: same JSON, 13ms
# instead of 84ms, and this runs for every mount on every bar tick.
rc() {
  local addr="$1" path="$2" query="${3:-}"
  [[ -n $addr ]] || return 1
  curl -sf -m 2 -X POST "http://$addr/$path${query:+?$query}" 2>/dev/null
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

read_meta() {  # remote, log, rc address
  local key="$1"
  meta_remote="" meta_log="" meta_rc=""
  [[ -f "$mounts_dir/$key.meta" ]] || return 1
  # A file written before the rc address was recorded has only two lines, so
  # the third read hits EOF: that is missing data, not a failure.
  { read -r meta_remote; read -r meta_log; read -r meta_rc; } < "$mounts_dir/$key.meta" || true
  [[ -n $meta_remote ]]
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

# Non-recursive on purpose: it re-reads the directory itself, which is the
# point when --dir-cache-time is measured in weeks. recursive=true would walk
# the whole remote.
do_refresh() {
  read_meta "$(key_for "$1")" || exit 1
  rc "$meta_rc" vfs/refresh >/dev/null || { echo "no rc on $1" >&2; exit 1; }
}

# Drop every queued upload's timer to zero so the write-back happens now.
do_flush() {
  local ids id
  read_meta "$(key_for "$1")" || exit 1
  ids=$(rc "$meta_rc" vfs/queue | jq -r '.queue[]? | select(.uploading != true) | .id') || exit 1
  for id in $ids; do rc "$meta_rc" vfs/queue-set-expiry "id=$id&expiry=0" >/dev/null; done
}

case "${1:-}" in
  unmount) do_unmount "${2:?mountpoint required}"; exit ;;
  remount) do_remount "${2:?mountpoint required}"; exit ;;
  refresh) do_refresh "${2:?mountpoint required}"; exit ;;
  flush)   do_flush   "${2:?mountpoint required}"; exit ;;
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
declare -A pid_of=() remote_of=() log_of=() rc_of=()
for cmdline in /proc/[0-9]*/cmdline; do
  pid=${cmdline#/proc/}; pid=${pid%/cmdline}
  mapfile -d '' -t argv 2>/dev/null < "$cmdline" || continue
  [[ ${#argv[@]} -ge 4 && ${argv[0]##*/} == rclone && ${argv[1]} == mount ]] || continue

  remote=${argv[2]} mp=${argv[3]} log="" rc_addr=""
  for ((i = 4; i < ${#argv[@]}; i++)); do
    case ${argv[i]} in
      --log-file=*) log=${argv[i]#--log-file=} ;;
      --log-file) log=${argv[i + 1]:-} ;;
      --rc-addr=*) rc_addr=${argv[i]#--rc-addr=} ;;
      --rc-addr) rc_addr=${argv[i + 1]:-} ;;
      # Bare --rc means rclone's own default address.
      --rc) [[ -n $rc_addr ]] || rc_addr="localhost:5572" ;;
    esac
  done

  pid_of["$mp"]=$pid remote_of["$mp"]=$remote log_of["$mp"]=$log rc_of["$mp"]=$rc_addr
  key=$(key_for "$mp")
  printf '%s\0' "${argv[@]}" > "$mounts_dir/$key.cmd"
  printf '%s\n%s\n%s\n' "$remote" "$log" "$rc_addr" > "$mounts_dir/$key.meta"
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
rc_cache_total=0
rc_seen=0

for mp in "${!seen[@]}"; do
  key=$(key_for "$mp")
  remote=${remote_of[$mp]:-} log=${log_of[$mp]:-} rc_addr=${rc_of[$mp]:-}
  if [[ -z $remote ]] && read_meta "$key"; then
    remote=$meta_remote log=$meta_log rc_addr=$meta_rc
  fi

  pid=${pid_of[$mp]:-0}
  vfs_stats="" core_stats=""
  if [[ -n $rc_addr ]]; then
    vfs_stats=$(rc "$rc_addr" vfs/stats)
    [[ -n $vfs_stats ]] && core_stats=$(rc "$rc_addr" core/stats)
  fi

  if [[ -n $vfs_stats ]]; then
    # An answering rc port is proof the process is alive and not wedged, which
    # a stat on a dead FUSE endpoint cannot tell you without blocking.
    status=ok
  elif [[ -n ${is_mounted[$mp]:-} ]]; then
    if timeout 2 stat -c %i -- "$mp" >/dev/null 2>&1; then status=ok; else status=stale; fi
  elif ((pid > 0)); then
    status=mounting
  else
    status=down
  fi

  errors=0 last_error=""
  if [[ -n $log && -r $log ]]; then
    # rclone re-reads an encrypted config periodically and logs a failure when
    # the temp file it wrote at startup is gone from /tmp. It keeps working on
    # the previous config, so counting it would just paint the widget red.
    mapfile -t error_lines < <(tail -n 2000 -- "$log" 2>/dev/null |
      grep -F " ERROR " | grep -F "$today" |
      grep -vF "Failed to read config file - using previous config")
    errors=${#error_lines[@]}
    ((errors > 0)) && last_error=${error_lines[-1]}
  fi

  about="{}"
  if [[ -n $remote ]]; then
    about_file="$cache_dir/about-$(key_for "$remote").json"
    if (($(age_of "$about_file") > about_ttl)); then
      if [[ -n $vfs_stats ]]; then
        # Through rc the running mount answers from its own decrypted config,
        # so this works even when the widget has no RCLONE_CONFIG_PASS.
        refresh_bg "$about_file" curl -sf -m 30 -X POST \
          "http://$rc_addr/operations/about?fs=$remote"
      else
        refresh_bg "$about_file" timeout 30 rclone about "$remote" --json
      fi
    fi
    [[ -s $about_file ]] && about=$(<"$about_file")
  fi

  queue="[]"
  if [[ -n $vfs_stats ]]; then
    ((rc_seen++))
    rc_cache_total=$((rc_cache_total + $(jq -r '.diskCache.bytesUsed // 0' <<< "$vfs_stats")))
    # Only ask for the queue when something is actually waiting.
    (($(jq -r '.diskCache.uploadsQueued // 0' <<< "$vfs_stats") > 0)) &&
      queue=$(rc "$rc_addr" vfs/queue | jq -c '.queue // []')
  fi

  rows+=("$(jq -cn \
    --arg mp "$mp" --arg remote "$remote" --arg status "$status" --arg log "$log" \
    --arg rcAddr "$rc_addr" --arg lastError "$last_error" \
    --argjson pid "$pid" --argjson errors "$errors" --argjson about "$about" \
    --argjson vfs "${vfs_stats:-null}" --argjson core "${core_stats:-null}" \
    --argjson queue "${queue:-[]}" \
    --argjson canRemount "$([[ -f "$mounts_dir/$key.cmd" ]] && echo true || echo false)" \
    '{path: $mp, remote: $remote, status: $status, pid: $pid, log: $log,
      errors: $errors, lastError: $lastError, canRemount: $canRemount,
      rcAddr: $rcAddr, hasRc: ($vfs != null),
      total: ($about.total // null), used: ($about.used // null), free: ($about.free // null),
      cacheBytes: ($vfs.diskCache.bytesUsed // null),
      cacheFiles: ($vfs.diskCache.files // null),
      outOfSpace: ($vfs.diskCache.outOfSpace // false),
      queued: ($vfs.diskCache.uploadsQueued // 0),
      uploading: ($vfs.diskCache.uploadsInProgress // 0),
      queue: ($queue | map({name, size, expiry, uploading})),
      speed: ($core.speed // 0), eta: ($core.eta // null),
      transferring: ($core.transferring // [] | map({name, percentage, speed}))}')")
done

# ---------------------------------------------------------------- cache size

# With rc every mount reports its own cache usage, which makes walking ~100GB
# of cache files pointless.
if ((rc_seen > 0)); then
  vfs_bytes=$rc_cache_total
else
  cache_file="$cache_dir/vfs-size"
  if [[ -d $vfs_dir ]] && (($(age_of "$cache_file") > cache_size_ttl)); then
    refresh_bg "$cache_file" bash -c 'du -sxb -- "$1" 2>/dev/null | cut -f1' _ "$vfs_dir"
  fi
  vfs_bytes=$(cat "$cache_file" 2>/dev/null)
  [[ $vfs_bytes =~ ^[0-9]+$ ]] || vfs_bytes=-1
fi

printf '%s\n' "${rows[@]:-}" | jq -sc \
  --argjson vfsBytes "$vfs_bytes" \
  'map(select(. != null)) | sort_by(.remote) |
   {mounts: .,
    total: length,
    ok: (map(select(.status == "ok")) | length),
    problems: (map(select(.status == "down" or .status == "stale")) | length),
    errors: (map(.errors) | add // 0),
    speed: (map(.speed) | add // 0),
    queued: (map(.queued) | add // 0),
    transferring: (map(.transferring | length) | add // 0),
    vfsBytes: $vfsBytes}'
