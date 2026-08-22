# omarchy-rclone

Rclone mount status in the [Omarchy](https://omarchy.org/) bar.

The bar shows a cloud plus the number of mounts, and turns red with a
crossed-out cloud the moment one of them is down or stale — the failure mode
that otherwise stays invisible, because a dead FUSE mount leaves the directory
sitting there looking empty.

The popup lists every mount with its status, remote usage, VFS cache size,
pending uploads, today's error count, and buttons to open it, refresh its
directory cache, upload what is queued, unmount it, or bring a dead one back.
While data is moving, the bar shows the transfer rate instead of the count.

## Mount with `--rc`

Live numbers — transfer rate, write-back queue, cache usage — come from
rclone's remote control, so mounts should run with it:

```bash
rclone mount GDrive: ~/GDrive ... --rc --rc-addr 127.0.0.1:5572 --rc-no-auth
```

One port per mount; the widget finds the address in the process command line,
so there is nothing to configure. Note that **`--rc` is incompatible with
`--daemon`**: the daemonizing parent binds the port and the child dies with
`address already in use`. Use `setsid --fork` instead.

Without `--rc` the widget still reports mount health and log errors, it just
cannot see speed, queue, or per-mount cache usage.

## Install

```bash
./install.sh          # copies into ~/.config/omarchy/plugins/io.github.dretureta.rclone
omarchy plugin enable io.github.dretureta.rclone
```

`install.sh` copies rather than symlinks: `omarchy plugin validate` rejects a
plugin folder that is a symlink.

## Development

Editing files under `~/.config/omarchy/plugins/` reloads plugin *code*, but a
bar widget that is already instantiated keeps running the old QML. After
`./install.sh`, run `omarchy restart shell` to actually see QML changes.

Glyphs must come from the Material Design plane (`U+F0000`+). Codepoints in
the BMP private-use area render from a different fallback font inside the
shell than they do anywhere else.

```bash
./state.sh | jq .      # what the widget sees
./check.sh             # full mount lifecycle against a throwaway :local: mount
```

## How it reads the system

- **Mounts** come from `/proc/self/mounts` (fstype `fuse.rclone`) unioned with
  the live `rclone mount` processes in `/proc`, so a mount whose process died
  is still listed instead of silently disappearing.
- **`ok` vs `stale`**: being in `/proc/self/mounts` is not enough — a dead
  endpoint stays mounted and only fails when touched, so each mount is probed
  with a `stat` under a timeout.
- **Remount** replays the exact argv saved from `/proc/<pid>/cmdline` while the
  mount was alive; once the process is gone that argv is unrecoverable, which
  is why it is cached under `~/.cache/omarchy-rclone/mounts/`.
- **Errors** are today's `ERROR` lines from the mount's `--log-file`, minus
  rclone's recurring "Failed to read config file - using previous config"
  message, which is benign and would otherwise keep the widget red.
- **Live data** comes from `vfs/stats`, `core/stats` and `vfs/queue` over rc,
  fetched with `curl` rather than `rclone rc` — same JSON, 13 ms instead of
  84 ms, and this runs for every mount on every tick.
- **Remote usage** goes through rc's `operations/about`, which the running
  mount answers from its own decrypted config. That matters with an encrypted
  `rclone.conf`: the shell process has no `RCLONE_CONFIG_PASS`, so spawning
  `rclone about` there would just hang on a password prompt.
- **VFS cache size** is what each mount reports over rc. Without rc it falls
  back to a `du`, cached and refreshed in a detached background job so the bar
  tick never blocks on it.

## Not here yet

Bandwidth limits (`core/bwlimit`), per-file cache eviction (`vfs/forget`), and
mounting remotes straight from the panel, which needs the `rclone rcd` +
`mount/mount` architecture rather than one rc port per mount process.
