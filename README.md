# omarchy-rclone

Rclone mount status in the [Omarchy](https://omarchy.org/) bar.

The bar shows a cloud plus the number of mounts, and turns red with a
crossed-out cloud the moment one of them is down or stale — the failure mode
that otherwise stays invisible, because a dead FUSE mount leaves the directory
sitting there looking empty.

The popup lists every mount with its status, remote usage, today's error count
from its log file, and buttons to open it, unmount it, or bring a dead one
back.

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
- **Errors** are today's `ERROR` lines from the mount's `--log-file`.
- **`rclone about` and the VFS cache size** are slow (an API call and a `du`
  over ~100 GB), so they are served from a cache and refreshed in a detached
  background job. The bar tick never blocks on them.

## Not here yet

Live transfer speed, VFS write-back queue, bandwidth limits, and cache
controls all need the mounts running with `--rc`.
