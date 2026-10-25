#!/bin/bash
# Builds TheeJ and runs it here, quitting any running copy first so the new build takes over.
set -e
cd "$(dirname "$0")"
# core.hooksPath is local config and does not survive a clone, so point it at the versioned
# hooks (.githooks/pre-commit blocks commits to main) the first time anyone runs this.
if [[ -d .git && -d .githooks && "$(git config --get core.hooksPath || true)" != ".githooks" ]]; then
    git config core.hooksPath .githooks
    echo "Enabled the repository git hooks."
fi
# Quit, not pkill: a killed copy counts as a crash, so the LaunchAgent would start it again.
# Before build.sh, which overwrites the binary the LaunchAgent runs.
if pgrep -x TheeJ >/dev/null; then osascript -e 'quit app id "com.zolfer.theej"'; fi
while pgrep -x TheeJ >/dev/null; do sleep 0.2; done
./build.sh --fast
# Opened by macOS, not run from this shell: macOS would hold the terminal responsible for TheeJ and ask
# whether the terminal may record audio, so no app's knob would work. The output still comes here, and
# Control-C still quits it.
output=()
if [ -t 0 ] && [ -t 1 ]; then output=(--stdout "$(tty)" --stderr "$(tty)"); fi
trap 'osascript -e "quit app id \"com.zolfer.theej\""' INT TERM
open -W "${output[@]}" .build/TheeJ.app --args "$@"
