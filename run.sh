#!/bin/bash
set -e
cd "$(dirname "$0")"
[ -x .build/TheeJ.app/Contents/MacOS/TheeJ ] || ./build.sh
exec .build/TheeJ.app/Contents/MacOS/TheeJ "$@"
