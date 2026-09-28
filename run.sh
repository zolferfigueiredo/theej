#!/bin/bash
set -e
cd "$(dirname "$0")"
[ -x .build/DeJota ] || ./build.sh
exec .build/DeJota "$@"
