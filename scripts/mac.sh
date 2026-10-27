#!/bin/sh
# Build / bundle / test RemotePU on a Mac (Command Line Tools are enough to build;
# tests use the Xcode toolchain when /Applications/Xcode.app exists).
#
#   scripts/mac.sh build              release build of all products
#   scripts/mac.sh bundle             build + dist/RemotePU.app (ad-hoc signed)
#   scripts/mac.sh recovery           bundle with a separate menu-bar app identity
#   scripts/mac.sh install            bundle + copy to ~/Applications/RemotePU.app
#   scripts/mac.sh run [-- args]      bundle + launch dist/RemotePU.app with args
#                                     e.g. scripts/mac.sh run -- --data-dir /tmp/rpu-test --demo
#   scripts/mac.sh test               swift tests + python collector tests
#   scripts/mac.sh agent              release rpu-agent-mac (+ .gz) into dist/
set -eu
cd "$(dirname "$0")/.."
cmd=${1:-bundle}
[ $# -gt 0 ] && shift

if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app/Contents/Developer ]; then
  TEST_DEV=/Applications/Xcode.app/Contents/Developer
else
  TEST_DEV=${DEVELOPER_DIR:-}
fi

APP=dist/RemotePU.app

build() {
  scripts/gen-collector.sh >/dev/null
  swift build -c release
  BIN=$(swift build -c release --show-bin-path)
}

agent() {
  mkdir -p dist
  cp "$BIN/rpu-agent-mac" dist/rpu-agent-mac
  strip -x dist/rpu-agent-mac
  codesign -f -s - dist/rpu-agent-mac 2>/dev/null
  gzip -9 -n -c dist/rpu-agent-mac > dist/rpu-agent-mac.gz
}

bundle() {
  build
  agent
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
  cp "$BIN/RemotePU" "$APP/Contents/MacOS/RemotePU"
  cp dist/rpu-agent-mac "$APP/Contents/Helpers/rpu-agent-mac"
  # Helpers/ may only contain code; the upload copy lives in Resources.
  cp dist/rpu-agent-mac.gz "$APP/Contents/Resources/rpu-agent-mac.gz"
  for h in rpu-askpass rpuctl rpu-probe; do
    cp "$BIN/$h" "$APP/Contents/Helpers/$h"
  done
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  cp -R Resources/*.lproj "$APP/Contents/Resources/"
  [ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
  for h in "$APP"/Contents/Helpers/*; do codesign -f -s - "$h" 2>/dev/null; done
  codesign -f -s - "$APP" 2>/dev/null
  codesign --verify --strict "$APP"
  echo "built $APP"
}

case $cmd in
  build) build ;;
  agent) build; agent; ls -l dist/rpu-agent-mac* ;;
  bundle) bundle ;;
  recovery)
    # Keep the normal bundle intact when ControlCenter has a corrupt record for
    # its identifier. Node settings, history and SSH keychain service are shared.
    APP=dist/RemotePU-Recovery.app
    bundle
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.remotepu.RemotePU.Recovery' "$APP/Contents/Info.plist"
    codesign -f -s - "$APP" 2>/dev/null
    codesign --verify --strict "$APP"
    echo "recovery bundle ready: $APP"
    ;;
  install)
    bundle
    mkdir -p "$HOME/Applications"
    if pgrep -x RemotePU >/dev/null; then
      osascript -e 'quit app "RemotePU"' 2>/dev/null || pkill -x RemotePU || true
      sleep 1
    fi
    rm -rf "$HOME/Applications/RemotePU.app"
    cp -R "$APP" "$HOME/Applications/"
    echo "installed ~/Applications/RemotePU.app"
    echo "control CLI: ~/Applications/RemotePU.app/Contents/Helpers/rpuctl"
    ;;
  run)
    bundle
    [ "${1:-}" = "--" ] && shift
    open -n "$APP" --args "$@"
    ;;
  test)
    scripts/gen-collector.sh >/dev/null
    if [ -n "$TEST_DEV" ]; then DEVELOPER_DIR=$TEST_DEV swift test; else swift test; fi
    python3 -m unittest discover -s collector/tests
    ;;
  *)
    sed -n '2,13p' "$0"
    exit 2
    ;;
esac
