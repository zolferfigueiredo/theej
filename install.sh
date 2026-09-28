#!/bin/bash
set -e
cd "$(dirname "$0")"

LABEL=com.zolfer.dejota
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
EXEC="$PWD/.build/DeJota"
LOG=/tmp/dejota.log

# The agent from before the rename to DeJota. Left running, it would fight this one for the port.
launchctl bootout "gui/$UID/com.user.deej-mac" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.user.deej-mac.plist"

if [ "$1" = "--uninstall" ]; then
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Uninstalled."
    exit 0
fi

[ -x "$EXEC" ] || ./build.sh

# A manual ./run.sh would fight the agent over the volume. Match the process name, not the
# command line: ./run.sh invokes it by relative path, and -f would also match this script.
pkill -x DeJota 2>/dev/null || true

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$EXEC</string>${1:+
        <string>$1</string>}
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict>
        <!-- Restart on a crash, but let Quit in the menu actually quit. -->
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>$LOG</string>
    <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed and running. It will start again at every login."
echo "Logs:      $LOG"
echo "Uninstall: ./install.sh --uninstall"
