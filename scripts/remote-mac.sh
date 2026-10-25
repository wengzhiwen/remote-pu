#!/bin/sh
# Develop on a non-Mac machine, build/test on a Mac over ssh.
#
#   scripts/remote-mac.sh [-h host] [-d dir] <command...>
#
# Syncs this repo (minus build products) to <host>:<dir> and runs <command> there, e.g.
#   scripts/remote-mac.sh swift build
#   scripts/remote-mac.sh swift test
#   scripts/remote-mac.sh scripts/mac.sh bundle
set -eu
# Private defaults (gitignored) may set RPU_MAC_HOST, e.g. local/env.sh.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$ROOT/local/env.sh" ] && . "$ROOT/local/env.sh"
HOST=${RPU_MAC_HOST:-}
DIR=${RPU_MAC_DIR:-/tmp/remote-pu-build}
while getopts "h:d:" opt; do
  case $opt in
    h) HOST=$OPTARG ;;
    d) DIR=$OPTARG ;;
    *) exit 2 ;;
  esac
done
shift $((OPTIND - 1))
if [ -z "$HOST" ]; then
  echo "set RPU_MAC_HOST=user@your-mac (or -h host); see local/env.sh" >&2
  exit 2
fi

tar -C "$ROOT" --exclude ./.build --exclude ./.git --exclude ./dist --exclude '*.pyc' --exclude __pycache__ \
    -czf - . | ssh -o BatchMode=yes "$HOST" "mkdir -p '$DIR' && tar -xzf - -C '$DIR' 2>/dev/null"
[ $# -eq 0 ] && exit 0
# shellcheck disable=SC2029
exec ssh -o BatchMode=yes "$HOST" "cd '$DIR' && $*"
