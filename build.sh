#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT/build/GPT55StatusBarApp.app"
BIN_DIR="$APP_DIR/Contents/MacOS"
RES_DIR="$APP_DIR/Contents/Resources"
SRC="$ROOT/Sources/main.swift"
PLIST="$ROOT/Info.plist"
BIN="$BIN_DIR/GPT55StatusBarApp"

rm -rf "$APP_DIR"
mkdir -p "$BIN_DIR" "$RES_DIR"

swiftc \
  -parse-as-library \
  -O \
  -framework AppKit \
  -framework SwiftUI \
  -framework Combine \
  "$SRC" \
  -o "$BIN"

cp "$PLIST" "$APP_DIR/Contents/Info.plist"
chmod +x "$BIN"

echo "$APP_DIR"
