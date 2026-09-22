#!/bin/bash
set -e
cd "$(dirname "$0")"
[ -x .build/deej-mac ] || ./build.sh
exec .build/deej-mac "$@"
