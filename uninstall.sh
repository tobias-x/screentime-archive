#!/bin/zsh
# Removes the launchd jobs, the archiver binary and the app. Keeps your archive unless --delete-archive.
set -euo pipefail
UID_NUM=$(id -u)
for label in io.github.tobias-x.screentime-archiver io.github.tobias-x.ScreenTimeBar; do
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done
rm -rf "$HOME/Applications/ScreenTimeBar.app" "$HOME/Library/Application Support/ScreenTimeArchive/bin"
if [[ "${1:-}" == "--delete-archive" ]]; then
    rm -rf "$HOME/Library/Application Support/ScreenTimeArchive" "$HOME/Library/Logs/ScreenTimeArchive"
    echo "Removed everything, including the archive."
else
    echo "Removed. Archive kept at ~/Library/Application Support/ScreenTimeArchive/archive.sqlite"
fi
echo "You can also remove screentime-archiver from Full Disk Access in System Settings."
