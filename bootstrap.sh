#!/bin/bash
# mac-rebuild bootstrap
#
# One-liner for a fresh Mac. Grabs Command Line Tools (which brings git),
# clones the repo, and hands off to setup.sh.
#
# Usage:
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JesseWebDotCom/macos-setup-scripts/main/bootstrap.sh)"

set -euo pipefail

REPO_URL="${MAC_REBUILD_REPO:-https://github.com/JesseWebDotCom/macos-setup-scripts.git}"
REPO_BRANCH="${MAC_REBUILD_BRANCH:-main}"
CLONE_DIR="${MAC_REBUILD_DIR:-$HOME/mac-rebuild}"

# ANSI helpers — kept lean; the fancy UI lives in setup.sh via SwiftDialog.
say()  { printf '\033[1;36m▶\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m✔\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m✖ %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(uname)" == "Darwin" ]] || die "This script only runs on macOS."

# 1) Command Line Tools — provides git, clang, make, and friends.
if ! xcode-select -p >/dev/null 2>&1; then
  say "Installing Xcode Command Line Tools (this pops a system dialog on some macOS versions)…"
  # Trick softwareupdate into showing CLT as an available update, then install headlessly.
  touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  CLT_LABEL="$(softwareupdate -l 2>/dev/null \
    | awk -F'*' '/\* Label: Command Line Tools/ {print $2}' \
    | sed -e 's/^ *Label: //' -e 's/[[:space:]]*$//' \
    | sort -V | tail -n1)"
  if [[ -n "${CLT_LABEL:-}" ]]; then
    sudo softwareupdate -i "$CLT_LABEL" --verbose || true
  fi
  rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  # Fallback: interactive installer if the headless path didn't take.
  if ! xcode-select -p >/dev/null 2>&1; then
    say "Falling back to interactive Command Line Tools installer — click through the prompt, then re-run this script."
    xcode-select --install || true
    die "Command Line Tools not present yet. Finish the installer and re-run the bootstrap."
  fi
  ok "Command Line Tools installed."
else
  ok "Command Line Tools already present."
fi

# 2) Clone (or update) the repo.
if [[ -d "$CLONE_DIR/.git" ]]; then
  say "Repo already at $CLONE_DIR — pulling latest."
  git -C "$CLONE_DIR" fetch --quiet origin "$REPO_BRANCH"
  git -C "$CLONE_DIR" checkout --quiet "$REPO_BRANCH"
  git -C "$CLONE_DIR" pull --quiet --ff-only
else
  say "Cloning $REPO_URL → $CLONE_DIR"
  git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$CLONE_DIR"
fi
ok "Repo ready at $CLONE_DIR."

# 3) Hand off. setup.sh needs sudo for installers, so re-launch under sudo.
say "Handing off to setup.sh — you'll be prompted for your password."
cd "$CLONE_DIR"
chmod +x setup.sh
exec sudo -E ./setup.sh "$@"
