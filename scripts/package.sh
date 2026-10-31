#!/usr/bin/env bash
set -euo pipefail

# Locate project root
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if [[ ! -f "plugin.toml" ]]; then
  echo "Error: plugin.toml not found in $ROOT_DIR" >&2
  exit 1
fi

# Extract plugin ID and version from plugin.toml
PLUGIN_ID=$(grep -E '^\s*id\s*=' plugin.toml | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')
PLUGIN_VERSION=$(grep -E '^\s*version\s*=' plugin.toml | head -n 1 | sed -E 's/.*"([^"]+)".*/\1/')

if [[ -z "$PLUGIN_ID" || -z "$PLUGIN_VERSION" ]]; then
  echo "Error: Failed to parse id or version from plugin.toml" >&2
  exit 1
fi

DIST_DIR="$ROOT_DIR/dist"
mkdir -p "$DIST_DIR"

TAR_FILE="$DIST_DIR/${PLUGIN_ID}-v${PLUGIN_VERSION}.tar.gz"
ZIP_FILE="$DIST_DIR/${PLUGIN_ID}-v${PLUGIN_VERSION}.zip"

# Create a temporary staging directory to assemble the package
STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT

TARGET_DIR="$STAGE_DIR/$PLUGIN_ID"
mkdir -p "$TARGET_DIR"

# Copy required files for the plugin
cp -R plugin.toml window.luau README.md tern-command-recall.plugin.zsh "$TARGET_DIR/"
mkdir -p "$TARGET_DIR/shell" "$TARGET_DIR/scripts"
cp shell/tern-recall.zsh "$TARGET_DIR/shell/"
cp scripts/install.sh "$TARGET_DIR/scripts/"

if [[ -f shell/test.zsh ]]; then
  cp shell/test.zsh "$TARGET_DIR/shell/"
fi
echo "📦 Packaging $PLUGIN_ID v$PLUGIN_VERSION..."

# 1. Create .tar.gz
tar -czf "$TAR_FILE" -C "$STAGE_DIR" "$PLUGIN_ID"
echo "  ✓ Generated: dist/${PLUGIN_ID}-v${PLUGIN_VERSION}.tar.gz"

# 2. Create .zip
(cd "$STAGE_DIR" && zip -qr "$ZIP_FILE" "$PLUGIN_ID")
echo "  ✓ Generated: dist/${PLUGIN_ID}-v${PLUGIN_VERSION}.zip"

echo ""
echo "✨ Packaged successfully into dist/:"
ls -lh "$TAR_FILE" "$ZIP_FILE"
echo ""
echo "To test installation of the packaged archive:"
echo "  1) Via direct extraction:"
echo "     tar -xzf \"$TAR_FILE\" -C \"\$HOME/Library/Application Support/Tern/plugins/\""
echo "     tern plugin reload $PLUGIN_ID"
echo ""
echo "  2) Via Tern CLI install:"
echo "     unzip -qo \"$ZIP_FILE\" -d /tmp/"
echo "     tern plugin install /tmp/$PLUGIN_ID --force"
