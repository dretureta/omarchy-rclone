#!/usr/bin/env bash
# Copy this checkout into the Omarchy plugin dir and reload the shell.
# (A symlinked plugin folder is rejected by `omarchy plugin validate`.)
set -euo pipefail
dest="$HOME/.config/omarchy/plugins/io.github.dretureta.rclone"
mkdir -p "$dest"
cp -f manifest.json Panel.qml state.sh README.md "$dest/"
chmod +x "$dest/state.sh"
omarchy plugin validate "$dest"
omarchy-shell shell rescanPlugins
