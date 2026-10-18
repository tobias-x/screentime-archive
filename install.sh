#!/bin/zsh
# Builds and installs the archiver (daily launchd job) and the menu bar app (starts at login).
# Re-run after changing code. Note: rebuilding changes the archiver's code signature, so macOS may
# drop its Full Disk Access; re-add it if the log shows permission errors.
set -euo pipefail
cd "${0:A:h}"

UID_NUM=$(id -u)
SUPPORT="$HOME/Library/Application Support/ScreenTimeArchive"
BIN="$SUPPORT/bin/screentime-archiver"
APP="$HOME/Applications/ScreenTimeBar.app"
LOGDIR="$HOME/Library/Logs/ScreenTimeArchive"
AGENTS="$HOME/Library/LaunchAgents"
ARCHIVER_LABEL=io.github.tobias-x.screentime-archiver
APP_LABEL=io.github.tobias-x.ScreenTimeBar

if (( $(sw_vers -productVersion | cut -d. -f1) < 14 )); then
    echo "Screen Time Archive needs macOS 14 or later." >&2
    exit 1
fi

./build.sh

mkdir -p "$SUPPORT/bin" "$HOME/Applications" "$LOGDIR" "$AGENTS"
install -m 755 build/screentime-archiver "$BIN"
rm -rf "$APP"
cp -R build/ScreenTimeBar.app "$APP"

# Daily archiver job: 12:30 every day, plus at login. launchd runs a missed calendar job on wake.
cat > "$AGENTS/$ARCHIVER_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$ARCHIVER_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$BIN</string></array>
    <key>StartCalendarInterval</key>
    <dict><key>Hour</key><integer>12</integer><key>Minute</key><integer>30</integer></dict>
    <key>RunAtLoad</key><true/>
    <key>ProcessType</key><string>Background</string>
    <key>LowPriorityIO</key><true/>
    <key>StandardOutPath</key><string>$LOGDIR/archiver.log</string>
    <key>StandardErrorPath</key><string>$LOGDIR/archiver.log</string>
</dict>
</plist>
EOF

# Menu bar app at login. KeepAlive only restarts it after a crash, not after "Quit".
cat > "$AGENTS/$APP_LABEL.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$APP_LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$APP/Contents/MacOS/ScreenTimeBar</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
    <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
EOF

for label in $ARCHIVER_LABEL $APP_LABEL; do
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_NUM" "$AGENTS/$label.plist"
done

echo
echo "Installed:"
echo "  archiver : $BIN"
echo "  app      : $APP"
echo "  archive  : $SUPPORT/archive.sqlite"
echo "  log      : $LOGDIR/archiver.log"
echo
echo "Next: give the archiver Full Disk Access (the app doesn't need it):"
echo "  System Settings › Privacy & Security › Full Disk Access › + , then press ⌘⇧G and paste:"
echo "  $BIN"
echo "Then run:  launchctl kickstart gui/$UID_NUM/$ARCHIVER_LABEL   (or click ↻ in the menu bar app)"
