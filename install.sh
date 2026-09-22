#!/bin/bash
set -e
cd "$(dirname "$0")"

LABEL=com.user.deej-mac
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
EXEC="$PWD/.build/deej-mac"

if [ "$1" = "--uninstall" ]; then
    launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Uninstalled."
    exit 0
fi

[ -x "$EXEC" ] || ./build.sh

# A manual ./run.sh would fight the agent over the volume. Match the process name, not the
# command line: ./run.sh invokes it by relative path, and -f would also match this script.
pkill -x deej-mac 2>/dev/null || true

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
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>5</integer>
    <key>StandardOutPath</key><string>/tmp/deej-mac.log</string>
    <key>StandardErrorPath</key><string>/tmp/deej-mac.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$PLIST"
echo "Installed and running. It will start again at every login."
echo "Logs:      /tmp/deej-mac.log"
echo "Uninstall: ./install.sh --uninstall"
