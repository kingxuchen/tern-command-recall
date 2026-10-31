#!/usr/bin/env zsh
# One-line universal installer for Ghostty, Otty, tty7, Tern, iTerm2, Alacritty:
#   curl -fsSL https://raw.githubusercontent.com/kingxuchen/tern-command-recall/main/scripts/install.sh | zsh
set -euo pipefail

REPO_URL="${COMMAND_RECALL_REPO:-https://github.com/kingxuchen/tern-command-recall.git}"
DATA_DIR="${TERN_RECALL_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/command-recall}"
INSTALL_DIR="${COMMAND_RECALL_INSTALL_DIR:-$DATA_DIR/plugin}"

# If invoked from a local checkout (`zsh scripts/install.sh`), use that checkout directly.
SCRIPT_SOURCE="${(%):-%x}"
if [[ -n "$SCRIPT_SOURCE" && -f "${SCRIPT_SOURCE:A:h:h}/shell/tern-recall.zsh" ]]; then
  INSTALL_DIR="${SCRIPT_SOURCE:A:h:h}"
else
  mkdir -p "${INSTALL_DIR:h}"
  if [[ -d "$INSTALL_DIR/.git" ]]; then
    git -C "$INSTALL_DIR" pull --ff-only --quiet
  elif [[ -e "$INSTALL_DIR" ]]; then
    print -ru2 -- "Error: $INSTALL_DIR already exists and is not a git repository."
    exit 1
  else
    git clone --depth 1 --quiet "$REPO_URL" "$INSTALL_DIR"
  fi
fi

/bin/zsh "$INSTALL_DIR/shell/tern-recall.zsh" --install
print -r -- "✓ Command Recall installed from: $INSTALL_DIR"
print -r -- "  Open a new terminal tab (or run: source ~/.zshrc) to activate in Ghostty, Otty, tty7, Tern, iTerm2."
