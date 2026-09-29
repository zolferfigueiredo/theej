#!/bin/bash
# Builds TheeJ and runs it here, quitting any running copy first so the new build takes over.
set -e
cd "$(dirname "$0")"
if [ "$1" != --selftest ]; then
    # Quit, not pkill: a killed copy counts as a crash, so the LaunchAgent would start it again.
    # Before build.sh, which overwrites the binary the LaunchAgent runs.
    if pgrep -x TheeJ >/dev/null; then osascript -e 'quit app id "com.zolfer.theej"'; fi
    while pgrep -x TheeJ >/dev/null; do sleep 0.2; done
fi
./build.sh
exec .build/TheeJ.app/Contents/MacOS/TheeJ "$@"
