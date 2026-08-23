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

## Run the mounts under systemd (recommended)

`systemd/rclone-mount@.service` is a template unit: one instance per mount,
with the per-mount details in `~/.config/rclone-mounts/<instance>.env` (see
`systemd/example.env`).

```bash
cp systemd/rclone-mount@.service ~/.config/systemd/user/
cp systemd/example.env ~/.config/rclone-mounts/gdrive.env   # then edit it
systemctl --user daemon-reload
systemctl --user enable --now rclone-mount@gdrive
```

Why bother, when a plain `rclone mount` works:

- **A crashed mount comes back by itself.** `Restart=on-failure` plus an
  `ExecStartPre` that clears the dead FUSE endpoint first — without that
  cleanup the restart fails, because even `mkdir` on a hung mountpoint returns
  "Transport endpoint is not connected".
- **`Type=notify`**, so `systemctl start` returns when the mount is actually
  readable rather than when the process spawned.
- **`TimeoutStopSec=120`**, so a shutdown lets the write-back queue finish
  uploading instead of killing it mid-flight.
- **The bare mountpoint is left read-only** (`chmod 0500` on stop). An unmounted
  mountpoint is just a directory, and anything that writes there — a backup run,
  a sync tool — lands on the local disk and then blocks the next mount, because
  rclone refuses a non-empty mountpoint. Better a permission error for whoever
  tried than a mount that will not come back after the next reboot.

The widget notices on its own: it reads the unit name from the process cgroup
and routes unmount and remount through `systemctl` — unmounting a
systemd-managed mount by hand only gets it restarted underneath you. The unit
counts only when its `MainPID` is the mount itself; a mount started by hand
inherits the cgroup of whatever spawned it, and stopping *that* would take down
the terminal, or the shell the widget lives in.

Remount also runs `reset-failed` first. A unit that failed enough times is rate
limited, and plain `restart` answers "Start request repeated too quickly" and
does nothing — which is exactly the state the button gets pressed in.

## Mount with `--rc`

Live numbers — transfer rate, write-back queue, cache usage — come from
rclone's remote control, so mounts should run with it:

```bash
rclone mount GDrive: ~/GDrive ... --rc --rc-addr unix://$XDG_RUNTIME_DIR/rclone-gdrive.sock --rc-no-auth
```

A unix socket rather than a loopback port: `$XDG_RUNTIME_DIR` is 0700, so the
socket is reachable by its owner and nobody else, while a port on localhost is
open to every local user. That matters here — rclone's own docs put rc access
on a par with shell access as the user running it. A `host:port` address still
works and the widget dials either; it finds the address in the process command
line, so there is nothing to configure.

Two things to know:

- **`--rc` is incompatible with `--daemon`.** The daemonizing parent binds the
  address and the child dies with `address already in use`, taking the mount
  with it. Use `setsid --fork`, or the systemd unit above.
- **A killed mount leaves its socket file behind**, and the next start fails to
  bind. The unit clears it in `ExecStartPre`; the widget's remount does the same
  before replaying a hand-started mount.

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
./check.sh glyphs      # icon codepoints only, instant
./check.sh             # the above, then the full mount lifecycle three times:
                       # no rc, rc over tcp, rc over a unix socket
```

The glyph step exists because a wrong icon never fails loudly: fontconfig
substitutes another font for a codepoint your font lacks, so the button renders
somebody else's picture. A codepoint *several* fonts claim is just as bad — the
shell may not resolve it the way a test render did. That is how `U+F052`, eject
in a Nerd Font, shipped here as a dot grid from Font Awesome 7. The check fails
on both cases and names the font it is competing with. (Idea from
[davidszp/omarchy-rclone](https://github.com/davidszp/omarchy-rclone), which
does the same thing by parsing the font's cmap.)

## Settings

Two, in the bar's plugin settings: how often to poll normally (15s), and while
the panel is open (2s).

Fast-when-open rather than fast-when-transferring: keying it off "something is
moving" was the first attempt and it never went quiet, because a mount with an
indexer walking it trickles files all day. Nobody is watching a number that
only lives in a closed panel, and the idle tier still has to be brisk enough to
notice a mount dying.

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
- **Notifications** fire on the ok ↔ broken transition, not on every tick: the
  last status per mount is kept on disk, so a crash systemd restarts within one
  tick never nags, and a red icon nobody is looking at is not the only signal.
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
