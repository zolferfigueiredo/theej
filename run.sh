#!/bin/bash
set -e
cd "$(dirname "$0")"
[ -x .build/DeJota.app/Contents/MacOS/DeJota ] || ./build.sh
exec .build/DeJota.app/Contents/MacOS/DeJota "$@"
