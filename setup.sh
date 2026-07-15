#!/bin/zsh --no-rcs
# mac-rebuild — main setup
#
# Runs under sudo. Called by bootstrap.sh, or invoked directly:
#   sudo ./setup.sh              # real run
#   sudo ./setup.sh --dry-run    # simulate everything on the target system
#
# Design:
#   - Apple-style SwiftDialog UI: one centered app icon + name at a time, small
#     subtitle ("Downloading Firefox 143.0.1…"), progress bar, "3 of 10".
#     Migration-Assistant-style, not busy Jamf-admin checklist.
#   - Cancel button. State file at /var/db/mac-rebuild/completed.txt so
#     re-running picks up where you left off.
#   - Claude Code installs via Anthropic's native installer (self-updating).
#   - App Auto-Patch runs weekly via a LaunchDaemon.

set -o pipefail
# Defensive: if user invokes via `sudo zsh setup.sh` and their ~/.zshrc turns
# on xtrace or verbose, kill both so we don't dump internals to their terminal.
setopt no_xtrace no_verbose

# Bumped every time this script changes. Printed on start so you can verify
# which version is actually running — if your log doesn't show the number
# below, you're on an older copy of setup.sh.
SETUP_VERSION="2026.07.15-r22-skip-claude-reinstall"

# ─── Flags ────────────────────────────────────────────────────────────────────

DRY_RUN=0
NO_DIALOG=0
RESET_STATE=0
UPDATE_ONLY=0
show_help() {
  cat <<EOF
mac-rebuild — Fresh Mac setup

Usage:
  sudo ./setup.sh                Full setup. Skips steps already completed.
  sudo ./setup.sh --update       Update mode. Only checks apps.conf entries
                                 (updates in place) and runs macOS updates.
                                 This is what /Applications/Update Apps.app
                                 runs when you double-click it.
  sudo ./setup.sh --dry-run      Preview. SwiftDialog + Installomator install
                                 (they're the harness). Everything else is
                                 simulated.
  sudo ./setup.sh --reset        Clear completed-steps state and start over.
  sudo ./setup.sh --no-dialog    Text-only progress; skip SwiftDialog UI.

Flags:
  -u, --update     Update apps.conf entries + macOS. Skip everything else.
  -n, --dry-run    Simulate target changes. Harness still installs.
      --no-dialog  Text-only progress (no SwiftDialog).
      --reset      Clear /var/db/mac-rebuild/completed.txt before running.
  -h, --help       Show this help.

Files:
  apps.conf                          Installomator labels (one per line).
  /var/log/mac-rebuild.log           Full log of every run.
  /var/db/mac-rebuild/completed.txt  Completed steps (used for resume).
  /usr/local/mac-rebuild/setup.sh    Stable copy used by Update Apps.app.
EOF
}
for arg in "$@"; do
  case "$arg" in
    -u|--update)  UPDATE_ONLY=1 ;;
    -n|--dry-run) DRY_RUN=1 ;;
    --no-dialog)  NO_DIALOG=1 ;;
    --reset)      RESET_STATE=1 ;;
    -h|--help)    show_help; exit 0 ;;
    *) echo "Unknown flag: $arg" >&2; show_help; exit 2 ;;
  esac
done

# ─── Preflight ────────────────────────────────────────────────────────────────

[[ "$(uname)" == "Darwin" ]] || { echo "macOS only." >&2; exit 1; }
if [[ $EUID -ne 0 ]]; then
  echo "Run under sudo: sudo $0 $*" >&2
  exit 1
fi

INVOKING_USER="${SUDO_USER:-$(/usr/bin/stat -f%Su /dev/console)}"
INVOKING_HOME="$(/usr/bin/dscl . -read "/Users/$INVOKING_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$INVOKING_HOME" ]] || INVOKING_HOME="/Users/$INVOKING_USER"

# Xcode Command Line Tools — bootstrap.sh normally handles this, but if
# setup.sh is invoked directly (skipping bootstrap) macOS pops a "install
# the tools?" GUI dialog the first time anything calls `git`. Force the
# silent softwareupdate install instead so nothing surprises the user.
if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
  echo "Xcode Command Line Tools not installed — installing silently (~5min)…" >&2
  /usr/bin/touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  CLT_LABEL="$(/usr/sbin/softwareupdate -l 2>/dev/null \
    | /usr/bin/awk -F'*' '/\* Label: Command Line Tools/ {print $2}' \
    | /usr/bin/sed -e 's/^ *Label: //' -e 's/[[:space:]]*$//' \
    | /usr/bin/sort -V | /usr/bin/tail -n1)"
  if [[ -n "${CLT_LABEL:-}" ]]; then
    /usr/sbin/softwareupdate -i "$CLT_LABEL" --verbose >&2 || true
  fi
  /bin/rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
  # If silent install failed for any reason, fall back to the GUI prompt.
  if ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    echo "Silent CLT install didn't finish — falling back to GUI prompt." >&2
    echo "Click Install in the dialog, then re-run this script." >&2
    /usr/bin/xcode-select --install >/dev/null 2>&1 || true
    exit 1
  fi
  echo "Command Line Tools installed." >&2
fi

SCRIPT_DIR="${0:A:h}"
APPS_CONF="$SCRIPT_DIR/apps.conf"
LOG_FILE="${MAC_REBUILD_LOG:-/var/log/mac-rebuild.log}"
[[ $DRY_RUN -eq 1 ]] && LOG_FILE="/var/log/mac-rebuild-dryrun.log"
DIALOG_CMD_FILE="/var/tmp/mac-rebuild-dialog.log"

STATE_DIR="/var/db/mac-rebuild"
STATE_FILE="$STATE_DIR/completed.txt"
mkdir -p "$STATE_DIR"
[[ $RESET_STATE -eq 1 ]] && rm -f "$STATE_FILE"
[[ $DRY_RUN -eq 1 ]]     && STATE_FILE="/var/tmp/mac-rebuild-dryrun-completed.txt" && : > "$STATE_FILE"
# Update mode: no state persistence — each run is independent.
[[ $UPDATE_ONLY -eq 1 ]] && STATE_FILE="/var/tmp/mac-rebuild-update-completed.txt" && : > "$STATE_FILE"
touch "$STATE_FILE"

# ─── Logging ──────────────────────────────────────────────────────────────────

: > "$LOG_FILE"
log()  { printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] ⚠  %s\n' "$(date '+%H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die()  { log "ERROR: $*"; [[ $USE_DIALOG -eq 1 ]] && dialog_finish "error" "$*"; exit 1; }

# ─── State file (resume support) ──────────────────────────────────────────────

is_done() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
mark_done() { grep -qxF "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"; }

# ─── Deps: SwiftDialog + Installomator ────────────────────────────────────────

fetch_latest_pkg_url() {
  local repo="$1" pattern="$2"
  curl -fsSL -H "Accept: application/vnd.github+json" \
       "https://api.github.com/repos/$repo/releases/latest" \
    | /usr/bin/grep -oE '"browser_download_url": *"[^"]+"' \
    | /usr/bin/awk -F'"' '{print $4}' \
    | /usr/bin/grep -E "$pattern" \
    | /usr/bin/head -n1
}

install_pkg_from_github() {
  # ALWAYS installs for real (harness), even in --dry-run.
  local name="$1" repo="$2" pattern="$3" fallback_url="${4:-}"
  local url pkg="/tmp/${name}.pkg"
  url="$(fetch_latest_pkg_url "$repo" "$pattern")"
  if [[ -z "$url" && -n "$fallback_url" ]]; then
    log "  GitHub API returned nothing — using fallback URL"
    url="$fallback_url"
  fi
  [[ -n "$url" ]] || { warn "No release URL for $name"; return 1; }
  log "  → $url"
  curl -fsSL --retry 3 -o "$pkg" "$url" || return 1
  installer -pkg "$pkg" -target / >>"$LOG_FILE" 2>&1 || return 1
  rm -f "$pkg"
}

ensure_swiftdialog() {
  if [[ -x /usr/local/bin/dialog ]]; then
    log "SwiftDialog present ($(/usr/local/bin/dialog --version 2>/dev/null))"
    return 0
  fi
  [[ $NO_DIALOG -eq 1 ]] && { log "SwiftDialog install skipped (--no-dialog)"; return 0; }
  log "Installing SwiftDialog…"
  install_pkg_from_github "dialog" "swiftDialog/swiftDialog" '\.pkg$' \
    "https://github.com/swiftDialog/swiftDialog/releases/latest/download/dialog.pkg" \
    || return 1
  [[ -x /usr/local/bin/dialog ]]
}

ensure_installomator() {
  if [[ -x /usr/local/Installomator/Installomator.sh ]]; then
    log "Installomator present"
    return 0
  fi
  log "Installing Installomator…"
  install_pkg_from_github "installomator" "Installomator/Installomator" '\.pkg$' \
    "https://github.com/Installomator/Installomator/releases/latest/download/Installomator.pkg" \
    || return 1
  [[ -x /usr/local/Installomator/Installomator.sh ]]
}

# ─── Label metadata (display name + SF icon) ──────────────────────────────────

label_display() {
  case "$1" in
    googlechromepkg)          echo "Google Chrome" ;;
    firefoxpkg)               echo "Firefox" ;;
    ghostty)                  echo "Ghostty" ;;
    homebrew)                 echo "Homebrew" ;;
    claudedesktop)            echo "Claude" ;;
    chatgpt)                  echo "ChatGPT" ;;
    vlc)                      echo "VLC" ;;
    plexdesktop)              echo "Plex" ;;
    keka)                     echo "Keka" ;;
    alttab)                   echo "AltTab" ;;
    hazel)                    echo "Hazel" ;;
    tailscale)                echo "Tailscale" ;;
    bartender)                echo "Bartender" ;;
    ice)                      echo "Ice" ;;
    balenaetcher)             echo "balenaEtcher" ;;
    rogueamoebasoundsource5)  echo "SoundSource" ;;
    microsoftwindowsapp)      echo "Windows App" ;;
    jumpdesktop)              echo "Jump Desktop" ;;
    realvncviewer)            echo "VNC Viewer" ;;
    rectangle)                echo "Rectangle" ;;
    1password8)               echo "1Password" ;;
    raycast)                  echo "Raycast" ;;
    __claudecode)             echo "Claude Code CLI" ;;
    __aiwrappers)             echo "AI CLI wrappers" ;;
    __defaults)               echo "macOS defaults" ;;
    __dock)                   echo "Dock cleanup" ;;
    __defaultbrowser)         echo "Default browser" ;;
    __aap)                    echo "App Auto-Patch" ;;
    __newfileservice)         echo "New Text File service" ;;
    __updatelauncher)         echo "Update Apps launcher" ;;
    __brewpackages)           echo "Homebrew packages" ;;
    __ohmyposh)               echo "Oh My Posh prompt" ;;
    __otherupdates)           echo "App Store + Office updates" ;;
    __updateallapps)          echo "Update all apps" ;;
    __osupdate)               echo "macOS updates" ;;
    *)                        echo "$1" ;;
  esac
}

# /Applications path per label — used to pull the real app icon when the app
# is already on disk. Empty for non-app steps.
label_app_path() {
  case "$1" in
    googlechromepkg)          echo "/Applications/Google Chrome.app" ;;
    firefoxpkg)               echo "/Applications/Firefox.app" ;;
    ghostty)                  echo "/Applications/Ghostty.app" ;;
    claudedesktop)            echo "/Applications/Claude.app" ;;
    chatgpt)                  echo "/Applications/ChatGPT.app" ;;
    vlc)                      echo "/Applications/VLC.app" ;;
    plexdesktop)              echo "/Applications/Plex.app" ;;
    keka)                     echo "/Applications/Keka.app" ;;
    alttab)                   echo "/Applications/AltTab.app" ;;
    hazel)                    echo "/Applications/Hazel.app" ;;
    tailscale)                echo "/Applications/Tailscale.app" ;;
    bartender)                echo "/Applications/Bartender 5.app" ;;
    ice)                      echo "/Applications/Ice.app" ;;
    balenaetcher)             echo "/Applications/balenaEtcher.app" ;;
    rogueamoebasoundsource5)  echo "/Applications/SoundSource.app" ;;
    microsoftwindowsapp)      echo "/Applications/Windows App.app" ;;
    jumpdesktop)              echo "/Applications/Jump Desktop.app" ;;
    realvncviewer)            echo "/Applications/VNC Viewer.app" ;;
    rectangle)                echo "/Applications/Rectangle.app" ;;
    1password8)               echo "/Applications/1Password.app" ;;
    raycast)                  echo "/Applications/Raycast.app" ;;
    *)                        echo "" ;;
  esac
}

# SF Symbol fallback per step — used when the .app doesn't exist yet.
label_sf() {
  case "$1" in
    googlechromepkg)          echo "SF=globe,colour=#4285F4" ;;
    firefoxpkg)               echo "SF=flame.fill,colour=#FF7139" ;;
    ghostty)                  echo "SF=terminal.fill,colour=#A96BFF" ;;
    homebrew)                 echo "SF=mug.fill,colour=#FBB040" ;;
    claudedesktop)            echo "SF=sparkles,colour=#D97757" ;;
    chatgpt)                  echo "SF=bubble.left.and.bubble.right.fill,colour=#10A37F" ;;
    vlc)                      echo "SF=play.rectangle.fill,colour=#FF8800" ;;
    plexdesktop)              echo "SF=tv.fill,colour=#EBAF00" ;;
    keka)                     echo "SF=archivebox.fill,colour=#5AC8FA" ;;
    alttab)                   echo "SF=rectangle.stack.fill,colour=#007AFF" ;;
    hazel)                    echo "SF=wand.and.stars,colour=#FF9500" ;;
    tailscale)                echo "SF=network,colour=#00A2FF" ;;
    bartender)                echo "SF=menubar.rectangle,colour=#8E8E93" ;;
    ice)                      echo "SF=snowflake,colour=#5AC8FA" ;;
    balenaetcher)             echo "SF=externaldrive.badge.plus,colour=#8B5CF6" ;;
    rogueamoebasoundsource5)  echo "SF=speaker.wave.3.fill,colour=#FF3B30" ;;
    microsoftwindowsapp)      echo "SF=display.2,colour=#0078D4" ;;
    jumpdesktop)              echo "SF=desktopcomputer.and.arrow.down,colour=#007AFF" ;;
    realvncviewer)            echo "SF=display.and.arrow.down,colour=#F19917" ;;
    rectangle)                echo "SF=rectangle.split.2x1,colour=#007AFF" ;;
    1password8)               echo "SF=key.horizontal.fill,colour=#0572EC" ;;
    raycast)                  echo "SF=magnifyingglass.circle.fill,colour=#FF6363" ;;
    __claudecode)             echo "SF=chevron.left.forwardslash.chevron.right,colour=#D97757" ;;
    __aiwrappers)             echo "SF=terminal.fill,colour=#D97757" ;;
    __defaults)               echo "SF=gearshape.fill,colour=#8E8E93" ;;
    __dock)                   echo "SF=dock.rectangle,colour=#007AFF" ;;
    __defaultbrowser)         echo "SF=safari.fill,colour=#FF7139" ;;
    __aap)                    echo "SF=arrow.triangle.2.circlepath.circle.fill,colour=#34C759" ;;
    __newfileservice)         echo "SF=doc.badge.plus,colour=#007AFF" ;;
    __updatelauncher)         echo "SF=arrow.down.app.fill,colour=#5856D6" ;;
    __brewpackages)           echo "SF=mug.fill,colour=#FBB040" ;;
    __ohmyposh)               echo "SF=command,colour=#7B68EE" ;;
    __otherupdates)           echo "SF=bag.fill,colour=#007AFF" ;;
    __updateallapps)          echo "SF=arrow.triangle.2.circlepath,colour=#007AFF" ;;
    __osupdate)               echo "SF=apple.logo,colour=#8E8E93" ;;
    *)                        echo "SF=shippingbox.fill,colour=gray" ;;
  esac
}

# Prefer the real app icon (from /Applications/…) if it's already on disk;
# otherwise fall back to the SF Symbol placeholder.
label_icon() {
  local app; app="$(label_app_path "$1")"
  if [[ -n "$app" && -d "$app" ]]; then
    echo "$app"
  else
    label_sf "$1"
  fi
}

# ─── SwiftDialog wrapper ──────────────────────────────────────────────────────

USE_DIALOG=0
typeset -a STEP_LABELS   # ordered internal keys (Installomator labels or __*)
STEP_LABELS=()

dialog_send() {
  [[ $USE_DIALOG -eq 1 ]] || return 0
  echo "$1" >> "$DIALOG_CMD_FILE"
}

# Check if the user clicked Cancel (dialog process is gone).
dialog_cancelled() {
  [[ $USE_DIALOG -eq 1 ]] || return 1
  ! kill -0 "$DIALOG_PID" 2>/dev/null
}

dialog_start() {
  if [[ $NO_DIALOG -eq 1 ]] || [[ ! -x /usr/local/bin/dialog ]]; then
    USE_DIALOG=0
    log "── Progress (text mode) ──"
    for l in "${STEP_LABELS[@]}"; do
      local mark="○"
      is_done "$l" && mark="✓"
      log "  $mark $(label_display "$l")"
    done
    return
  fi
  USE_DIALOG=1
  : > "$DIALOG_CMD_FILE"
  chmod 644 "$DIALOG_CMD_FILE" 2>/dev/null || true

  # Count what's already done so we can position the counter correctly.
  local done_count=0
  for l in "${STEP_LABELS[@]}"; do is_done "$l" && done_count=$((done_count + 1)); done

  local intro
  if [[ $DRY_RUN -eq 1 ]]; then
    intro="Dry run — nothing on this Mac will change."
  elif [[ $UPDATE_ONLY -eq 1 ]]; then
    intro="Checking for updates."
  elif [[ $done_count -gt 0 ]]; then
    intro="Resuming from where you left off."
  else
    intro="Grab a coffee. This runs unattended."
  fi

  # ── Apple-style: single centered icon that changes per step. No checklist. ──
  # Icon starts as a generic laptop; each run_step updates it via `icon:` cmds.
  # Same for title (becomes the current app) and message (becomes status text).
  /usr/local/bin/dialog \
    --title "Setting up your Mac" \
    --titlefont "size=22,weight=semibold" \
    --message "$intro" \
    --messagefont "size=13,colour=#8E8E93" \
    --messagealignment center \
    --icon "SF=laptopcomputer,colour=#007AFF,weight=light" \
    --iconsize 128 \
    --centericon \
    --progress "${#STEP_LABELS[@]}" \
    --progresstext "Starting…" \
    --commandfile "$DIALOG_CMD_FILE" \
    --moveable --ontop \
    --button1disabled --button1text "Working…" \
    --button2text "Cancel" \
    --position center \
    --width 460 --height 340 \
    &!
  DIALOG_PID=$!
  sleep 0.6
}

# The dialog is a single centered "card" that updates in place:
#   [icon]                      ← changes per step (label_icon)
#   Firefox                     ← --message, bold, changes per step
#   Downloading 143.0.1…        ← --progresstext, Installomator writes live
#   ━━━━━━━━━━━━━━━━━━━━━━━     ← progress bar
#
# Signature: dialog_step LABEL PHASE [DETAIL]
#   PHASE = starting | active | done | failed
dialog_step() {
  local label="$1" phase="$2" detail="${3:-}"
  local name; name="$(label_display "$label")"
  local icon; icon="$(label_icon "$label")"
  [[ $USE_DIALOG -eq 0 ]] && return 0
  case "$phase" in
    starting)
      dialog_send "icon: $icon"
      dialog_send "message: $name"
      dialog_send "progresstext: Preparing…"
      ;;
    active)
      # Explicit phase text (e.g. "Applying macOS defaults…") for steps that
      # don't have Installomator writing progresstext for us.
      [[ -n "$detail" ]] && dialog_send "progresstext: $detail"
      ;;
    done)
      # Re-fetch the icon — a fresh Installomator run just put the .app on
      # disk, so label_icon can now return the real bundle icon.
      # $detail lets the work function pass a custom completion message
      # (e.g. "Already up to date", "Updated to 143.0.1") instead of just
      # the app name.
      local msg="${detail:-$name}"
      dialog_send "icon: $(label_icon "$label")"
      dialog_send "progresstext: ✓ $msg"
      ;;
    failed)
      dialog_send "progresstext: ⚠ $name failed — see log"
      ;;
  esac
}

# Text-mode fallback for status lines.
log_step() {
  local label="$1" phase="$2" detail="${3:-}"
  local name; name="$(label_display "$label")"
  local marker="…"
  case "$phase" in
    done)   marker="✓" ;;
    failed) marker="✗" ;;
  esac
  [[ $USE_DIALOG -eq 0 ]] && log "  $marker $name${detail:+ — $detail}"
}

dialog_progress() {
  local n="$1"
  [[ $USE_DIALOG -eq 1 ]] && dialog_send "progress: $n"
}

dialog_finish() {
  local kind="$1" msg="$2"
  if [[ $USE_DIALOG -eq 1 ]]; then
    if [[ "$kind" == "success" ]]; then
      dialog_send "icon: SF=checkmark.seal.fill,colour=#34C759"
      dialog_send "message: All set"
      dialog_send "progress: complete"
      dialog_send "progresstext: $msg"
    elif [[ "$kind" == "cancelled" ]]; then
      dialog_send "icon: SF=pause.circle.fill,colour=#FF9500"
      dialog_send "message: Paused"
      dialog_send "progresstext: $msg"
    else
      dialog_send "icon: SF=exclamationmark.triangle.fill,colour=#FF3B30"
      dialog_send "message: Something went wrong"
      dialog_send "progresstext: $msg"
    fi
    dialog_send "button1: enable"
    dialog_send "button1text: Close"
    # (SwiftDialog can't hide button2 after launch — leaving Cancel visible;
    # clicking it just closes the dialog same as Close at this point.)
  fi
  log "── $kind ── $msg"
  log "Full log: $LOG_FILE"
}

# ─── Load app list from apps.conf ─────────────────────────────────────────────

typeset -a APP_LABELS
if [[ -f "$APPS_CONF" ]]; then
  while IFS= read -r line; do
    line="${line%%#*}"
    line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && APP_LABELS+=("$line")
  done < "$APPS_CONF"
fi

# Build the ordered step list.
# Full setup: apps + all system steps.
# Update mode: apps only + macOS updates (skip defaults/dock/browser/AAP/etc.
#              since they're already configured from the initial setup run).
if [[ $UPDATE_ONLY -eq 1 ]]; then
  # Update mode: don't iterate apps.conf. Instead __updateallapps runs AAP
  # silently — AAP scans /Applications for every app that has an
  # Installomator label and patches whatever's out of date. Our own dialog
  # drives the UI (icon + name + phase) by parsing AAP's log in real time.
  STEP_LABELS+=("__updateallapps" "__brewpackages" "__otherupdates" "__osupdate")
else
  # Full setup: iterate apps.conf for initial installs; other steps follow.
  for l in "${APP_LABELS[@]}"; do STEP_LABELS+=("$l"); done
  STEP_LABELS+=("__brewpackages" "__ohmyposh" "__claudecode" "__aiwrappers" \
                "__defaults" "__dock" "__defaultbrowser" "__newfileservice" \
                "__updatelauncher" "__aap" "__otherupdates" "__osupdate")
fi

# ─── Kick off ─────────────────────────────────────────────────────────────────

log "════════════════════════════════════════════════════════"
log " mac-rebuild — starting (version $SETUP_VERSION)"
[[ $DRY_RUN -eq 1 ]] && log " MODE:  DRY RUN — target changes simulated"
log " User:  $INVOKING_USER"
log " Log:   $LOG_FILE"
log " State: $STATE_FILE  ($(wc -l < "$STATE_FILE" | tr -d ' ') step(s) already done)"
log " Steps: ${#STEP_LABELS[@]}"
log "════════════════════════════════════════════════════════"

ensure_swiftdialog  || die "Could not install SwiftDialog"
ensure_installomator || die "Could not install Installomator"

dialog_start

# Progress counter reflects total completed (including previously-done steps).
progress=0
for l in "${STEP_LABELS[@]}"; do is_done "$l" && progress=$((progress + 1)); done

# Helper: runs a single step's work function and handles state + cancellation.
run_step() {
  local label="$1" work_fn="$2"
  local name; name="$(label_display "$label")"

  if is_done "$label"; then
    log "[$name] already done — skipping"
    progress=$((progress + 1))
    dialog_progress "$progress"
    return 0
  fi
  if dialog_cancelled; then
    log "User cancelled — stopping before $name"
    return 99
  fi

  progress=$((progress + 1))
  dialog_step "$label" "starting"
  dialog_progress "$progress"
  log_step "$label" "starting"

  # STEP_RESULT_TEXT is set by work functions that want a custom "done"
  # message ("Already up to date", "Updated to 143.0.1", …). Reset here.
  STEP_RESULT_TEXT=""
  if "$work_fn" "$label"; then
    if [[ $DRY_RUN -eq 1 ]]; then
      dialog_step "$label" "done" "Simulated"
    else
      dialog_step "$label" "done" "$STEP_RESULT_TEXT"
    fi
    mark_done "$label"
    log "[$name] OK${STEP_RESULT_TEXT:+ — $STEP_RESULT_TEXT}"
    log_step "$label" "done" "$STEP_RESULT_TEXT"
    sleep 0.3   # brief flourish before the next step overwrites
  else
    dialog_step "$label" "failed"
    log "[$name] FAILED"
    log_step "$label" "failed"
  fi
}

# ─── Work functions per step ──────────────────────────────────────────────────

INSTALLOMATOR=/usr/local/Installomator/Installomator.sh
# Notes on Installomator args:
#   • BLOCKING_PROCESS_ACTION=kill — batch setup, no user prompts to wait on.
#     "tell_user_then_kill" waited 5 minutes per blocked app (VLC etc.) for a
#     dialog response we never routed to it.
#   • DIALOG_CMD_FILE is intentionally OMITTED. When set, Installomator's
#     piped download path reads pipestatus[1] outside the subshell that ran
#     the pipeline, which returns stale/wrong exit codes and lets silent curl
#     failures slip through (observed with VLC/Keka/Bartender/VNC Viewer —
#     shasum reports "No such file" and install fails with hdiutil "attach
#     failed"). The non-piped path uses `$?` correctly.
installomator_args=(
  BLOCKING_PROCESS_ACTION=kill
  NOTIFY=silent
  LOGGING=REQ
  LOGO=appstore
  DEBUG=$DRY_RUN
)

work_installomator() {
  local label="$1"
  local name; name="$(label_display "$label")"
  # Installomator checks the installed version first and skips work if the
  # app is already current — so "Checking…" is honest for every case (fresh
  # install, upgrade, or no-op). We look at its output afterward to tell the
  # user what actually happened.
  dialog_step "$label" "active" "Checking…"

  local capture="/var/tmp/mac-rebuild-io-$$-$$.log"
  "$INSTALLOMATOR" "$label" \
    "${installomator_args[@]}" \
    >"$capture" 2>&1
  local rc=$?
  cat "$capture" >> "$LOG_FILE"

  # Parse Installomator's output to figure out the outcome.
  if [[ $rc -eq 0 ]]; then
    if /usr/bin/grep -qE "same as installed|latest version.*already installed|is already installed" "$capture"; then
      STEP_RESULT_TEXT="Already up to date"
    elif /usr/bin/grep -qE ": Installed .*, version " "$capture"; then
      local ver
      ver="$(/usr/bin/grep -oE ": Installed [^,]+, version [^ ]+" "$capture" \
             | tail -1 | awk '{print $NF}')"
      # If Installomator's initial version check found the same version
      # already installed, treat this as an update; otherwise it's a fresh
      # install. Simplest heuristic: presence of "app already installed" text.
      STEP_RESULT_TEXT="Updated to ${ver:-latest}"
    fi
  fi

  rm -f "$capture"
  return $rc
}

work_claudecode() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Claude Code CLI] [dry-run] would run: curl -fsSL https://claude.ai/install.sh | bash (as $INVOKING_USER)"
    dialog_step "__claudecode" "active" "Downloading (simulated)…"
    sleep 0.5
    dialog_step "__claudecode" "active" "Installing (simulated)…"
    sleep 0.5
    return 0
  fi
  # Only run the installer if Claude Code isn't already present. It
  # auto-updates itself in the background, so re-running the network
  # installer on every setup just re-downloads it for nothing. (Force a
  # reinstall by removing ~/.local/bin/claude first.)
  if [[ -x "$INVOKING_HOME/.local/bin/claude" ]]; then
    log "[Claude Code CLI] already installed — skipping installer (self-updates)"
    dialog_step "__claudecode" "active" "Already installed"
    STEP_RESULT_TEXT="Already installed"
  else
    dialog_step "__claudecode" "active" "Downloading…"
    sudo -u "$INVOKING_USER" -H bash -c \
      'curl -fsSL https://claude.ai/install.sh | bash' \
      >>"$LOG_FILE" 2>&1 || return 1
  fi

  # The installer adds ~/.local/bin to PATH in whatever shell profile it
  # detects — under our bash -c invocation that's bash's, not zsh's (the
  # macOS default). Guarantee the zsh side ourselves (idempotent marker).
  local zshrc="$INVOKING_HOME/.zshrc"
  local marker="# mac-rebuild:claude-code-path"
  sudo -u "$INVOKING_USER" touch "$zshrc"
  if ! grep -qF "$marker" "$zshrc" 2>/dev/null; then
    sudo -u "$INVOKING_USER" tee -a "$zshrc" >/dev/null <<EOF

$marker
export PATH="\$HOME/.local/bin:\$PATH"
EOF
    log "[Claude Code CLI] added ~/.local/bin to PATH in .zshrc"
  fi
}

# Themed AI-CLI wrappers written to a sourced zsh file.
#   claude   → subtle orange background wash, normal claude
#   clauded  → pronounced orange + `claude --dangerously-skip-permissions`
#   codex    → subtle blue background wash, normal codex
#   codexd   → pronounced blue + `codex --dangerously-bypass-approvals-and-sandbox`
# The background wash uses OSC-11 (set) / OSC-111 (reset), which Ghostty and
# most modern terminals honor; it resets automatically when the app exits,
# even on Ctrl-C (zsh `always` block). Lives in its own file so it can be
# regenerated cleanly; ~/.zshrc just sources it (idempotent marker).
work_aiwrappers() {
  local cfg_dir="$INVOKING_HOME/.config/mac-rebuild"
  local ai_file="$cfg_dir/shell-ai.zsh"
  local zshrc="$INVOKING_HOME/.zshrc"
  local marker="# mac-rebuild:ai-wrappers"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[AI CLI wrappers] [dry-run] would write $ai_file and source it from ~/.zshrc"
    dialog_step "__aiwrappers" "active" "Configuring (simulated)…"
    sleep 0.4
    STEP_RESULT_TEXT="Simulated"
    return 0
  fi

  dialog_step "__aiwrappers" "active" "Writing wrappers…"
  sudo -u "$INVOKING_USER" mkdir -p "$cfg_dir"

  # Write the wrapper definitions. Colors are dark background tints:
  #   subtle    = barely-there wash you notice peripherally
  #   pronounced = clearly saturated so "dangerous" mode is unmistakable
  sudo -u "$INVOKING_USER" tee "$ai_file" >/dev/null <<'AIWRAP'
# mac-rebuild AI CLI wrappers — regenerated by setup.sh; edits are overwritten.
#
#   claude   subtle orange (Gruvbox)     codex    subtle blue (Tokyo Night)
#   clauded  bold   orange + dangerous   codexd   bold   blue + dangerous
#
# Each wrapper sets a COHESIVE palette — background + foreground + cursor —
# so text stays readable (a lone background wash over your normal fg looks
# muddy). Warm tones are Gruvbox-derived; cool tones Tokyo-Night-derived.
# All three reset when the app exits, even on Ctrl-C (zsh `always` block),
# via OSC 110/111/112.

# OSC 11=background, 10=foreground, 12=cursor. \a (BEL) ends each sequence.
_mr_theme_on()  { printf '\033]11;%s\a\033]10;%s\a\033]12;%s\a' "$1" "$2" "$3"; }
_mr_theme_off() { printf '\033]111\a\033]110\a\033]112\a'; }

# Run "$@" under a bg/fg/cursor palette that always resets afterward.
_mr_themed() {
  emulate -L zsh
  local bg="$1" fg="$2" cur="$3"; shift 3
  local rc=0
  _mr_theme_on "$bg" "$fg" "$cur"
  {
    "$@"
    rc=$?
  } always {
    _mr_theme_off
  }
  return $rc
}

#                    background   foreground   cursor
# ── Claude Code — warm / Gruvbox ──
claude()  { _mr_themed "#2b2622" "#ebdbb2" "#fe8019" command claude "$@"; }
clauded() {
  print -P "%F{208}⚠  clauded — --dangerously-skip-permissions%f"
  _mr_themed "#3a2414" "#f5e6c8" "#ff9e3b" command claude --dangerously-skip-permissions "$@"
}

# ── OpenAI Codex — cool / Tokyo Night ──
codex()  { _mr_themed "#1a1f2e" "#c0caf5" "#7aa2f7" command codex "$@"; }
codexd() {
  print -P "%F{75}⚠  codexd — --dangerously-bypass-approvals-and-sandbox%f"
  _mr_themed "#111d38" "#d5e2ff" "#7dcfff" command codex --dangerously-bypass-approvals-and-sandbox "$@"
}
AIWRAP

  chown "$INVOKING_USER" "$ai_file"

  # Source it from .zshrc (once).
  dialog_step "__aiwrappers" "active" "Wiring ~/.zshrc…"
  sudo -u "$INVOKING_USER" touch "$zshrc"
  if ! grep -qF "$marker" "$zshrc" 2>/dev/null; then
    sudo -u "$INVOKING_USER" tee -a "$zshrc" >/dev/null <<EOF

$marker
[ -f "$ai_file" ] && source "$ai_file"
EOF
    log "[AI CLI wrappers] sourced $ai_file from .zshrc"
  else
    log "[AI CLI wrappers] .zshrc already wired"
  fi

  STEP_RESULT_TEXT="claude/clauded, codex/codexd"
}

work_defaults() {
  local defaults_script; defaults_script=$(cat <<'DEFAULTS'
    defaults write -g AppleInterfaceStyle -string "Dark"
    defaults write com.apple.finder AppleShowAllFiles -bool true
    defaults write NSGlobalDomain AppleShowAllExtensions -bool true
    defaults write com.apple.finder ShowPathbar -bool true
    defaults write com.apple.finder ShowStatusBar -bool true
    defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"
    defaults write com.apple.finder FXDefaultSearchScope -string "SCcf"
    defaults write com.apple.finder _FXSortFoldersFirst -bool true
    defaults write com.apple.finder NewWindowTarget -string "PfHm"
    defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode -bool true
    defaults write NSGlobalDomain PMPrintingExpandedStateForPrint -bool true
    defaults write com.apple.finder FXEnableExtensionChangeWarning -bool false
    defaults write com.apple.dock autohide -bool true
    defaults write com.apple.dock autohide-time-modifier -float 0.4
    defaults write com.apple.dock show-recents -bool false
    defaults write com.apple.dock tilesize -int 42
    defaults write com.apple.dock mineffect -string "scale"
    defaults write com.apple.dock minimize-to-application -bool true
    defaults write com.apple.controlcenter "NSStatusItem Visible Battery" -bool true
    defaults -currentHost write com.apple.controlcenter BatteryShowPercentage -bool true
    mkdir -p "$HOME/Pictures/Screenshots"
    defaults write com.apple.screencapture location -string "$HOME/Pictures/Screenshots"
    defaults write com.apple.screencapture type -string "png"
    defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false
    defaults write NSGlobalDomain KeyRepeat -int 2
    defaults write NSGlobalDomain InitialKeyRepeat -int 15
    defaults write com.apple.driver.AppleBluetoothMultitouch.trackpad Clicking -bool true
    defaults -currentHost write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
    defaults write NSGlobalDomain com.apple.mouse.tapBehavior -int 1
    defaults write com.apple.Safari IncludeDevelopMenu -bool true 2>/dev/null || true
    defaults write com.apple.Safari WebKitDeveloperExtrasEnabledPreferenceKey -bool true 2>/dev/null || true
    defaults write com.apple.TextEdit RichText -int 0
    defaults write NSGlobalDomain NSNavPanelExpandedStateForSaveMode2 -bool true
    defaults write com.apple.WindowManager EnableTilingByEdgeDrag -bool true
    defaults write com.apple.WindowManager EnableTilingOptionAccelerator -bool true
    defaults write com.apple.WindowManager EnableTiledWindowMargins -bool true
    defaults write com.apple.TimeMachine DoNotOfferNewDisksForBackup -bool true
DEFAULTS
  )
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[macOS defaults] [dry-run] would apply ~30 defaults commands"
    log "  Dark mode • Finder tweaks • Dock • Battery % • Screenshots → ~/Pictures/Screenshots"
    log "  Fast key repeat • Tap-to-click • Window tiling margins • Time Machine prompt off"
    dialog_step "__defaults" "active" "Applying (simulated)…"
    sleep 0.7
    return 0
  fi
  dialog_step "__defaults" "active" "Applying…"
  sudo -u "$INVOKING_USER" -H zsh -c "$defaults_script" >>"$LOG_FILE" 2>&1 || return 1
  for app in Finder Dock SystemUIServer ControlCenter WindowManager; do
    /usr/bin/killall "$app" 2>/dev/null || true
  done
}

# Build a tiny AppleScript "New Text File.app" in /Applications and enable
# Finder toolbar drag. When clicked (from toolbar, Launchpad, or Spotlight)
# it creates `untitled.txt` (unique name) in the frontmost Finder window's
# folder. Not a right-click quick action per se, but the practical result:
# one-click new-file creation from Finder, no third-party purchase needed.
work_newfileservice() {
  local app_path="/Applications/New Text File.app"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[New Text File service] [dry-run] would osacompile → $app_path"
    log "  drag it onto Finder's toolbar (Cmd-drag) for one-click new file"
    dialog_step "__newfileservice" "active" "Compiling (simulated)…"
    sleep 0.5
    return 0
  fi

  dialog_step "__newfileservice" "active" "Compiling…"

  # The AppleScript. Creates untitled.txt (or untitled-N.txt if collision) in
  # the folder shown by the frontmost Finder window; falls back to Desktop.
  local script
  script=$(cat <<'APPLESCRIPT'
tell application "Finder"
    try
        set targetFolder to (folder of the front window) as alias
    on error
        set targetFolder to (path to desktop folder) as alias
    end try
    set baseName to "untitled"
    set fileExt to ".txt"
    set fileName to baseName & fileExt
    set counter to 1
    repeat while exists file fileName of targetFolder
        set fileName to baseName & "-" & counter & fileExt
        set counter to counter + 1
    end repeat
    set newFile to make new file at targetFolder with properties {name:fileName}
    select newFile
    activate
end tell
APPLESCRIPT
  )

  rm -rf "$app_path"
  /usr/bin/osacompile -o "$app_path" -e "$script" >>"$LOG_FILE" 2>&1 || return 1

  # Give it our SF Symbol until the user drags it to the toolbar (macOS uses
  # the app's icon for both the toolbar and app-icon views). osacompile
  # produces a default AppleScript icon; that's fine and Apple-native.

  log "[New Text File service] created $app_path"
  log "  → Drag $app_path onto any Finder window's toolbar (hold Cmd while dragging)"
  log "     for one-click new-file creation. Or invoke via Spotlight/Launchpad."
}

# Install a stable copy of setup.sh + apps.conf at /usr/local/mac-rebuild/,
# then build /Applications/Update Apps.app — a small AppleScript app that
# runs `setup.sh --update` as admin. Double-click the app and you get the
# native macOS password prompt, then the same minimal SwiftDialog UI as this
# setup, but only cycling through apps + macOS updates.
work_updatelauncher() {
  local stable_dir="/usr/local/mac-rebuild"
  local stable_setup="$stable_dir/setup.sh"
  local stable_conf="$stable_dir/apps.conf"
  local launcher="/Applications/Update Apps.app"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Update Apps launcher] [dry-run] would copy setup.sh + apps.conf to $stable_dir"
    log "[Update Apps launcher] [dry-run] would build $launcher"
    dialog_step "__updatelauncher" "active" "Creating (simulated)…"
    sleep 0.5
    return 0
  fi

  dialog_step "__updatelauncher" "active" "Installing stable copy…"
  mkdir -p "$stable_dir"
  cp "$SCRIPT_DIR/setup.sh" "$stable_setup"
  cp "$SCRIPT_DIR/apps.conf" "$stable_conf"
  chown -R root:wheel "$stable_dir"
  chmod 755 "$stable_setup"
  chmod 644 "$stable_conf"

  dialog_step "__updatelauncher" "active" "Building Update Apps.app…"
  local applescript
  applescript=$(cat <<'APPLESCRIPT'
try
    do shell script "/bin/zsh /usr/local/mac-rebuild/setup.sh --update 2>&1" ¬
        with administrator privileges
on error errMsg number errNum
    -- -128 is user-cancelled the password prompt; ignore silently.
    if errNum is not -128 then
        display alert "Update Apps failed" message errMsg as critical
    end if
end try
APPLESCRIPT
  )
  rm -rf "$launcher"
  /usr/bin/osacompile -o "$launcher" -e "$applescript" >>"$LOG_FILE" 2>&1 || return 1

  log "[Update Apps launcher] created $launcher"
  log "  → Double-click to check + update all apps in apps.conf"
}

# Dock cleanup using dockutil.
#   • Removes: Maps, Photos, Games, Reminders (whatever Apple pinned by default)
#   • Adds:    Firefox pinned after Safari
# dockutil is a Python CLI installed via Installomator; edits the user's
# ~/Library/Preferences/com.apple.dock.plist. We invoke it as the user so the
# per-user plist is updated in place.
work_dock() {
  # Resolve dockutil location — the .pkg installs to /usr/local/bin.
  local du
  if [[ -x /usr/local/bin/dockutil ]]; then
    du=/usr/local/bin/dockutil
  elif command -v dockutil >/dev/null 2>&1; then
    du="$(command -v dockutil)"
  fi
  local ff_app="/Applications/Firefox.app"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Dock cleanup] [dry-run] would install dockutil, then:"
    log "  dockutil --remove Maps/Photos/Games/Reminders"
    log "  dockutil --add $ff_app --after Safari"
    dialog_step "__dock" "active" "Editing Dock (simulated)…"
    sleep 0.6
    return 0
  fi

  # Ensure dockutil is on disk.
  if [[ -z "$du" || ! -x "$du" ]]; then
    dialog_step "__dock" "active" "Installing dockutil…"
    "$INSTALLOMATOR" dockutil "${installomator_args[@]}" >>"$LOG_FILE" 2>&1 || return 1
    du=/usr/local/bin/dockutil
    [[ -x "$du" ]] || { warn "dockutil not found after install"; return 1; }
  fi
  log "[Dock] using $du"

  dialog_step "__dock" "active" "Removing built-in apps…"
  # NO explicit plist path — modern dockutil uses cfprefsd via `defaults`,
  # which respects the running preferences daemon. Passing a plist path
  # writes directly to the file and cfprefsd overwrites your edits on next
  # flush — that's why the prior version appeared to succeed but nothing
  # changed. --no-restart batches; we restart Dock once at the end.
  local removed=0
  for app in Maps Photos Games Reminders; do
    if sudo -u "$INVOKING_USER" "$du" --remove "$app" --no-restart \
         >>"$LOG_FILE" 2>&1; then
      removed=$((removed + 1))
      log "  removed: $app"
    else
      log "  not in Dock: $app (skipped)"
    fi
  done

  local firefox_pinned=0
  if [[ -d "$ff_app" ]]; then
    dialog_step "__dock" "active" "Pinning Firefox…"
    if sudo -u "$INVOKING_USER" "$du" --find "Firefox" >>"$LOG_FILE" 2>&1; then
      log "  Firefox already in Dock"
      firefox_pinned=1
    elif sudo -u "$INVOKING_USER" "$du" --add "$ff_app" --after "Safari" \
           --no-restart >>"$LOG_FILE" 2>&1; then
      log "  pinned Firefox after Safari"
      firefox_pinned=1
    elif sudo -u "$INVOKING_USER" "$du" --add "$ff_app" --no-restart \
           >>"$LOG_FILE" 2>&1; then
      log "  pinned Firefox (default position — Safari not in Dock)"
      firefox_pinned=1
    else
      warn "failed to pin Firefox"
    fi
  else
    warn "Firefox.app not found — skipping pin"
  fi

  # Restart Dock so changes take effect immediately.
  sudo -u "$INVOKING_USER" killall Dock 2>/dev/null || true

  STEP_RESULT_TEXT="Removed $removed"
  [[ $firefox_pinned -eq 1 ]] && STEP_RESULT_TEXT+=", pinned Firefox"
}

# Install (or upgrade) the Homebrew packages listed in brew.conf.
# Runs as the invoking user — Homebrew refuses to run as root.
work_brewpackages() {
  # Ensure Homebrew itself is installed. We use the OFFICIAL install script
  # (`curl … | bash`) rather than Installomator's `homebrew` .pkg label,
  # because that .pkg has been unreliable when invoked non-interactively as
  # root — it reports exit 0 but often leaves nothing on disk. The official
  # script writes to /opt/homebrew (Apple Silicon) or /usr/local (Intel).
  local brewbin=""
  if [[ -x /opt/homebrew/bin/brew ]]; then
    brewbin=/opt/homebrew/bin/brew
  elif [[ -x /usr/local/bin/brew ]]; then
    brewbin=/usr/local/bin/brew
  fi

  if [[ -z "$brewbin" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      log "[Homebrew] [dry-run] would git-clone Homebrew to /opt/homebrew"
    else
      # Manual install per Homebrew's "Alternative Installs" docs:
      #   https://docs.brew.sh/Installation#untar-anywhere-unsupported
      # We deliberately don't use `curl | bash` — that path needs passwordless
      # sudo cached for INVOKING_USER, which `sudo -u USER` from root doesn't
      # inherit, so the official installer aborts immediately.
      # Instead: root mkdirs and chowns, then user git-clones. No sudo inside.
      dialog_step "__brewpackages" "active" "Installing Homebrew…"
      local prefix="/opt/homebrew"
      log "[Homebrew] git-clone install → $prefix"
      mkdir -p "$prefix"
      chown -R "$INVOKING_USER":admin "$prefix"
      sudo -u "$INVOKING_USER" -H /usr/bin/git clone --depth=1 \
        https://github.com/Homebrew/brew "$prefix" \
        >>"$LOG_FILE" 2>&1 || { warn "git clone of Homebrew failed"; return 1; }
      # First-run: initialise Cellar, Caskroom, etc. `brew update --force`
      # populates the taps and stops brew from complaining about a bare tree.
      sudo -u "$INVOKING_USER" -H "$prefix/bin/brew" update --force --quiet \
        >>"$LOG_FILE" 2>&1 || true
      # Zsh completion dir must not be world-writable or zsh's compinit refuses.
      chmod -R go-w "$prefix/share/zsh" 2>/dev/null || true
      brewbin="$prefix/bin/brew"
      [[ -x "$brewbin" ]] || { warn "brew binary missing after install"; return 1; }
      log "[Homebrew] installed at $brewbin"
    fi
  else
    log "[Homebrew] present at $brewbin"
  fi

  # Ensure Homebrew's bin dir is on PATH for interactive shells. The git-clone
  # install (and even the .pkg) never runs `brew shellenv` wiring, so without
  # this every brew-installed CLI (gh, jq, rg, python, ffmpeg, oh-my-posh…) is
  # on disk but invisible to `which`. Add the standard shellenv line to
  # ~/.zshrc, idempotently. Also export into THIS process so the rest of the
  # run (e.g. codex cask, brew upgrades) can find brew's tools.
  if [[ $DRY_RUN -eq 0 ]]; then
    local brew_prefix; brew_prefix="$(dirname "$(dirname "$brewbin")")"
    local zshrc="$INVOKING_HOME/.zshrc"
    local marker="# mac-rebuild:homebrew-shellenv"
    sudo -u "$INVOKING_USER" touch "$zshrc"
    if ! grep -qF "$marker" "$zshrc" 2>/dev/null; then
      sudo -u "$INVOKING_USER" tee -a "$zshrc" >/dev/null <<EOF

$marker
eval "\$($brewbin shellenv)"
EOF
      log "[Homebrew] added shellenv to .zshrc (puts $brew_prefix/bin on PATH)"
    fi
    eval "$("$brewbin" shellenv)" 2>/dev/null || true
  fi

  # Parse brew.conf.
  local brewconf="$SCRIPT_DIR/brew.conf"
  [[ -f "$brewconf" ]] || { log "no brew.conf — skipping"; STEP_RESULT_TEXT="No brew.conf"; return 0; }
  local -a packages
  while IFS= read -r line; do
    line="${line%%#*}"; line="${line//[[:space:]]/}"
    [[ -n "$line" ]] && packages+=("$line")
  done < "$brewconf"
  [[ ${#packages[@]} -eq 0 ]] && { STEP_RESULT_TEXT="Nothing to install"; return 0; }

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Homebrew packages] [dry-run] would install/upgrade: ${packages[*]}"
    dialog_step "__brewpackages" "active" "Installing (simulated)…"
    sleep 0.6
    STEP_RESULT_TEXT="${#packages[@]} packages (simulated)"
    return 0
  fi

  # brew MUST NOT run as root. sudo -u drops back to the invoking user;
  # -H sets HOME correctly so brew's caches land in the right place.
  local as_user=(sudo -u "$INVOKING_USER" -H)

  dialog_step "__brewpackages" "active" "Updating formulae…"
  "${as_user[@]}" "$brewbin" update >>"$LOG_FILE" 2>&1 || true

  # Install each package individually so a single failure doesn't hide behind
  # `|| true` on a batch install and get miscounted. (Prior versions ran
  # `brew install pkg1 pkg2 …` in one shot — if e.g. oh-my-posh failed, brew
  # exited non-zero, `|| true` swallowed it, and the step lied that all 20
  # succeeded.)
  local ok_count=0 failed=()
  local i=0 total=${#packages[@]}
  for pkg in "${packages[@]}"; do
    i=$((i + 1))
    dialog_step "__brewpackages" "active" "Installing $pkg ($i/$total)…"
    if "${as_user[@]}" "$brewbin" install "$pkg" >>"$LOG_FILE" 2>&1; then
      ok_count=$((ok_count + 1))
      # Upgrade if a newer version exists (brew install is a no-op on
      # already-installed packages; this catches version bumps).
      "${as_user[@]}" "$brewbin" upgrade "$pkg" >>"$LOG_FILE" 2>&1 || true
    else
      failed+=("$pkg")
      warn "brew install $pkg failed — see log"
    fi
  done

  if [[ ${#failed[@]} -eq 0 ]]; then
    STEP_RESULT_TEXT="$ok_count formulae"
  else
    STEP_RESULT_TEXT="$ok_count OK, ${#failed[@]} failed"
    log "[Homebrew packages] failed: ${failed[*]}"
  fi
}

# Set Firefox as the default browser.
# macOS Big Sur+ requires a user-visible confirmation dialog for this change —
# the tool triggers that dialog; the user clicks "Use Firefox" to complete it.
# Uses macadmins/default-browser (signed .pkg, Go binary at
# /opt/macadmins/bin/default-browser).
work_defaultbrowser() {
  local ff_app="/Applications/Firefox.app"
  local tool="/opt/macadmins/bin/default-browser"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Default browser] [dry-run] would install macadmins/default-browser"
    log "  then run: default-browser --identifier org.mozilla.firefox"
    log "  (macOS will pop a confirmation dialog — user clicks 'Use Firefox')"
    dialog_step "__defaultbrowser" "active" "Setting Firefox (simulated)…"
    sleep 0.5
    return 0
  fi

  if [[ ! -d "$ff_app" ]]; then
    warn "Firefox.app not found — cannot set as default browser"
    return 1
  fi

  if [[ ! -x "$tool" ]]; then
    dialog_step "__defaultbrowser" "active" "Installing default-browser tool…"
    install_pkg_from_github "default-browser" "macadmins/default-browser" '\.pkg$' \
      || return 1
  fi

  dialog_step "__defaultbrowser" "active" "Confirm the prompt on screen…"
  # Run as the user; macOS will show the "Do you want to change your default
  # browser to Firefox?" system dialog. User clicks "Use Firefox".
  sudo -u "$INVOKING_USER" "$tool" --identifier org.mozilla.firefox \
    >>"$LOG_FILE" 2>&1
}

# Update every installed app that has an Installomator label.
#
# Uses App Auto-Patch under the hood — AAP scans /Applications, matches each
# installed app to an Installomator label, and patches everything out of date.
# We run AAP silently and drive our own minimal Apple-style dialog by tailing
# AAP's log in the background — so the user never sees AAP's own UI or its
# name in the window title. On each new app AAP touches, our dialog swaps
# the icon and updates the phase text.
work_updateallapps() {
  local aap="/usr/local/bin/appautopatch"
  local aap_folder="/Library/Management/AppAutoPatch"
  local aap_log="$aap_folder/logs/aap.log"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Update all apps] [dry-run] would run: appautopatch --workflow-install-now --interactiveMode=0"
    dialog_step "__updateallapps" "active" "Scanning apps (simulated)…"
    for app in "Google Chrome" "Firefox" "VLC" "Slack"; do
      dialog_send "icon: SF=shippingbox.fill,colour=#8E8E93"
      dialog_send "message: $app"
      dialog_send "progresstext: Checking…"
      sleep 0.4
    done
    STEP_RESULT_TEXT="Simulated"
    return 0
  fi

  if [[ ! -x "$aap" ]]; then
    warn "appautopatch not installed — run 'sudo zsh setup.sh' first (full setup)"
    return 1
  fi

  # Prep log location so we can tail from clean.
  mkdir -p "$aap_folder/logs"
  : > "$aap_log"

  # Initial dialog state.
  dialog_send "icon: SF=magnifyingglass.circle.fill,colour=#007AFF"
  dialog_send "message: Scanning your apps"
  dialog_send "progresstext: Discovering installed apps…"

  # Fire AAP silently in the background. All its output goes to our log too.
  ("$aap" --workflow-install-now --interactiveMode=0 >>"$LOG_FILE" 2>&1) &
  local aap_pid=$!

  # Poll AAP's log for the current app + phase. AAP's log lines look like:
  #   [INFO] Found <AppName>.app version <ver>       ← analyzing this app
  #   [NOTICE] --- Publicly available version: <ver>
  #   [NOTICE] --- <ver> is-at-least <ver>.          ← up to date
  #   [NOTICE] --- Latest version installed.         ← up to date
  #   [INSTALL] Installing <name>                    ← patching
  #   Installed <name>, version <ver>                ← done
  local current_app="" last_line=""
  while kill -0 "$aap_pid" 2>/dev/null; do
    if [[ -s "$aap_log" ]]; then
      local recent
      recent="$(tail -50 "$aap_log" 2>/dev/null \
                | /usr/bin/grep -E 'Found [^.]+\.app|Latest version installed|is-at-least|Installing |Installed [^,]+, version ' \
                | tail -1)"
      if [[ -n "$recent" && "$recent" != "$last_line" ]]; then
        last_line="$recent"
        if [[ "$recent" =~ Found[[:space:]]([A-Za-z0-9._[:space:]-]+)\.app ]]; then
          current_app="${match[1]}"
          local app_path="/Applications/${current_app}.app"
          if [[ -d "$app_path" ]]; then
            dialog_send "icon: $app_path"
          else
            dialog_send "icon: SF=shippingbox.fill,colour=#8E8E93"
          fi
          dialog_send "message: $current_app"
          dialog_send "progresstext: Checking…"
        elif [[ "$recent" =~ (Latest[[:space:]]version[[:space:]]installed|is-at-least) ]]; then
          [[ -n "$current_app" ]] && dialog_send "progresstext: Already up to date"
        elif [[ "$recent" =~ Installing[[:space:]]([A-Za-z0-9._[:space:]-]+) ]]; then
          local iapp="${match[1]}"
          dialog_send "message: $iapp"
          dialog_send "progresstext: Installing…"
        elif [[ "$recent" =~ Installed[[:space:]]([A-Za-z0-9._[:space:]-]+),[[:space:]]version[[:space:]]([^[:space:]]+) ]]; then
          local iapp="${match[1]}" ver="${match[2]}"
          dialog_send "message: $iapp"
          dialog_send "progresstext: Updated to $ver"
        fi
      fi
    fi
    sleep 0.3
  done

  # AAP exited — collect its exit code.
  wait "$aap_pid"
  local rc=$?

  # Count actual updates by grepping the log.
  local updated
  updated="$(/usr/bin/grep -cE 'Installed [^,]+, version ' "$aap_log" 2>/dev/null | tr -d ' ')"
  updated="${updated:-0}"

  if [[ "$updated" == "0" ]]; then
    STEP_RESULT_TEXT="Everything up to date"
  elif [[ "$updated" == "1" ]]; then
    STEP_RESULT_TEXT="1 app updated"
  else
    STEP_RESULT_TEXT="$updated apps updated"
  fi

  return $rc
}

# Wire up Oh My Posh + Nerd Font for a nice zsh prompt.
#   • Adds `eval "$(oh-my-posh init zsh ...)"` to ~/.zshrc (idempotent).
#   • Uses the `jandedobbeleer` theme (Oh My Posh author's own default).
#   • Points Ghostty at MesloLGS Nerd Font Mono so the prompt's icons/glyphs
#     render correctly.
# Depends on `oh-my-posh` and `font-meslo-lg-nerd-font` from brew.conf.
work_ohmyposh() {
  local zshrc="$INVOKING_HOME/.zshrc"
  local ghostty_dir="$INVOKING_HOME/.config/ghostty"
  local ghostty_config="$ghostty_dir/config"
  local font_family="MesloLGS Nerd Font Mono"
  local marker="# mac-rebuild:oh-my-posh"

  # Find oh-my-posh.
  local omp
  if [[ -x /opt/homebrew/bin/oh-my-posh ]]; then
    omp=/opt/homebrew/bin/oh-my-posh
  elif [[ -x /usr/local/bin/oh-my-posh ]]; then
    omp=/usr/local/bin/oh-my-posh
  fi

  # Theme lives under brew's share/oh-my-posh/themes/.
  local theme=""
  if [[ -n "$omp" ]]; then
    local prefix; prefix="$(dirname "$(dirname "$omp")")"
    theme="$prefix/share/oh-my-posh/themes/jandedobbeleer.omp.json"
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Oh My Posh] [dry-run] would append init line to $zshrc"
    log "[Oh My Posh] [dry-run] would set Ghostty font to $font_family"
    dialog_step "__ohmyposh" "active" "Configuring (simulated)…"
    sleep 0.4
    STEP_RESULT_TEXT="Simulated"
    return 0
  fi

  [[ -x "$omp" ]] || { warn "oh-my-posh not installed — add to brew.conf"; return 1; }
  [[ -f "$theme" ]] || { warn "theme not found at $theme"; return 1; }

  # ── .zshrc ──
  dialog_step "__ohmyposh" "active" "Wiring ~/.zshrc…"
  # Create/own .zshrc as the user
  sudo -u "$INVOKING_USER" touch "$zshrc"
  if grep -qF "$marker" "$zshrc" 2>/dev/null; then
    log "[Oh My Posh] .zshrc already wired"
  else
    sudo -u "$INVOKING_USER" tee -a "$zshrc" >/dev/null <<EOF

$marker
eval "\$($omp init zsh --config '$theme')"
EOF
    log "[Oh My Posh] appended init line to $zshrc"
  fi

  # ── Ghostty font ──
  dialog_step "__ohmyposh" "active" "Setting Ghostty font…"
  sudo -u "$INVOKING_USER" mkdir -p "$ghostty_dir"
  sudo -u "$INVOKING_USER" touch "$ghostty_config"
  if grep -qE "^font-family[[:space:]]*=" "$ghostty_config" 2>/dev/null; then
    # Replace existing font-family line
    sudo -u "$INVOKING_USER" /usr/bin/sed -i '' \
      "s|^font-family[[:space:]]*=.*|font-family = $font_family|" \
      "$ghostty_config"
    log "[Oh My Posh] updated Ghostty font-family"
  else
    sudo -u "$INVOKING_USER" tee -a "$ghostty_config" >/dev/null <<EOF

# mac-rebuild: Nerd Font for Oh My Posh glyphs
font-family = $font_family
font-size = 14
EOF
    log "[Oh My Posh] wrote Ghostty font config"
  fi

  STEP_RESULT_TEXT="Wired to jandedobbeleer"
}

# Third-party updaters — anything that isn't Installomator, Homebrew, or
# `softwareupdate`. Currently:
#   • mas — Mac App Store CLI, updates all MAS apps if signed in
#   • msupdate — Microsoft AutoUpdate, updates Office/Teams if installed
# Silently skipped if the tool isn't present.
work_otherupdates() {
  local mas_bin=""
  [[ -x /opt/homebrew/bin/mas ]] && mas_bin=/opt/homebrew/bin/mas
  [[ -x /usr/local/bin/mas ]]    && mas_bin=/usr/local/bin/mas
  local msupdate="/Library/Application Support/Microsoft/MAU2.0/Microsoft AutoUpdate.app/Contents/MacOS/msupdate"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[Other updates] [dry-run] would run mas upgrade + msupdate --install"
    dialog_step "__otherupdates" "active" "Checking (simulated)…"
    sleep 0.5
    STEP_RESULT_TEXT="Simulated"
    return 0
  fi

  local ran_anything=0 summary=""

  # ── Mac App Store ──
  if [[ -n "$mas_bin" && -x "$mas_bin" ]]; then
    dialog_step "__otherupdates" "active" "Checking App Store…"
    log "[Other updates] mas outdated"
    local mas_out
    mas_out="$(sudo -u "$INVOKING_USER" "$mas_bin" outdated 2>&1)"
    echo "$mas_out" >> "$LOG_FILE"
    if [[ -z "$mas_out" ]]; then
      log "  App Store: everything current"
    else
      local count; count="$(echo "$mas_out" | wc -l | tr -d ' ')"
      dialog_step "__otherupdates" "active" "Updating $count App Store apps…"
      sudo -u "$INVOKING_USER" "$mas_bin" upgrade >>"$LOG_FILE" 2>&1 || true
      summary+="MAS: $count updated"
    fi
    ran_anything=1
  else
    log "[Other updates] mas not installed — skipping App Store (add it to brew.conf)"
  fi

  # ── Microsoft AutoUpdate ──
  # msupdate only patches Office/Teams/OneDrive/Defender — apps registered
  # with Microsoft AutoUpdate. It does NOT patch Windows App (that updates
  # itself). If none of the MAU-registered apps are installed, skip entirely
  # and save the user from staring at a stuck "Updating Microsoft apps…"
  # dialog for several minutes while `msupdate` phones home for nothing.
  local -a ms_apps
  ms_apps=(
    "/Applications/Microsoft Word.app"
    "/Applications/Microsoft Excel.app"
    "/Applications/Microsoft PowerPoint.app"
    "/Applications/Microsoft Outlook.app"
    "/Applications/Microsoft OneNote.app"
    "/Applications/Microsoft Teams.app"
    "/Applications/Microsoft Teams classic.app"
    "/Applications/OneDrive.app"
    "/Applications/Microsoft Defender.app"
    "/Applications/Microsoft Edge.app"
  )
  local has_office=0
  for app in "${ms_apps[@]}"; do
    [[ -d "$app" ]] && { has_office=1; break; }
  done

  if [[ ! -x "$msupdate" ]]; then
    log "[Other updates] Microsoft AutoUpdate not present — skipping"
  elif [[ $has_office -eq 0 ]]; then
    log "[Other updates] No Office/Teams/OneDrive apps installed — skipping msupdate"
    log "  (Windows App doesn't use msupdate; it updates itself)"
  else
    dialog_step "__otherupdates" "active" "Checking Microsoft apps…"
    log "[Other updates] msupdate --list (60s timeout)"
    # 60-second cap so a hung msupdate can't stall the whole run.
    local ms_out
    ms_out="$(/usr/bin/perl -e 'alarm shift @ARGV; exec @ARGV' 60 "$msupdate" --list 2>&1)" || true
    echo "$ms_out" >> "$LOG_FILE"
    if echo "$ms_out" | /usr/bin/grep -qE "Available application update|^\* "; then
      dialog_step "__otherupdates" "active" "Updating Microsoft apps…"
      log "[Other updates] msupdate --install (updates available)"
      "$msupdate" --install >>"$LOG_FILE" 2>&1 || true
      [[ -n "$summary" ]] && summary+=", "
      summary+="Microsoft apps updated"
    else
      log "[Other updates] Microsoft apps up to date"
      [[ -n "$summary" ]] && summary+=", "
      summary+="Microsoft up to date"
    fi
    ran_anything=1
  fi

  if [[ $ran_anything -eq 0 ]]; then
    STEP_RESULT_TEXT="Nothing to check"
  elif [[ -n "$summary" ]]; then
    STEP_RESULT_TEXT="$summary"
  else
    STEP_RESULT_TEXT="Up to date"
  fi
}

# macOS system updates. Uses `softwareupdate` — Apple's CLI for the same
# updates that show up in System Settings → General → Software Update.
# We don't auto-restart because the script itself is running from Terminal —
# rebooting mid-script kills logging and cleanup. If a restart-required
# update installs, we flag OS_RESTART_NEEDED so the final message tells the
# user to restart when convenient.
work_osupdate() {
  if [[ $DRY_RUN -eq 1 ]]; then
    log "[macOS updates] [dry-run] would: softwareupdate -l"
    log "                              softwareupdate -i -a --agree-to-license"
    dialog_step "__osupdate" "active" "Checking (simulated)…"
    sleep 0.5
    dialog_step "__osupdate" "active" "Installing (simulated)…"
    sleep 0.6
    return 0
  fi

  dialog_step "__osupdate" "active" "Checking for updates…"
  log "[macOS updates] softwareupdate -l"
  local list_output
  list_output="$(softwareupdate -l 2>&1)"
  echo "$list_output" >> "$LOG_FILE"

  # "No new software available" (macOS 26+) or older phrasings.
  if echo "$list_output" | grep -qiE "no new software|no updates available"; then
    log "[macOS updates] already up to date"
    dialog_step "__osupdate" "active" "Already up to date"
    sleep 0.4
    return 0
  fi

  # Parse the pending update labels.
  local -a all_labels installable
  all_labels=("${(@f)$(echo "$list_output" \
    | /usr/bin/awk -F'Label: ' '/\* Label: /{print $2}' \
    | /usr/bin/sed 's/[[:space:]]*$//')}")

  # Skip Command Line Tools updates. Preflight already guarantees a working
  # CLT, and on beta seeds Apple offers a new 500MB CLT beta continually —
  # installing it every run is slow churn that never clears the queue.
  for l in "${all_labels[@]}"; do
    [[ -z "$l" ]] && continue
    if [[ "$l" == *"Command Line Tools"* ]]; then
      log "[macOS updates] skipping: $l (CLT churn — preflight manages CLT)"
    else
      installable+=("$l")
    fi
  done

  if [[ ${#installable[@]} -eq 0 ]]; then
    log "[macOS updates] nothing to install after filtering"
    dialog_step "__osupdate" "active" "Up to date"
    STEP_RESULT_TEXT="Up to date"
    sleep 0.4
    return 0
  fi

  local restart_required=0
  if echo "$list_output" | grep -qiE "action:\s*restart|requires.*restart|\[restart\]"; then
    restart_required=1
  fi

  log "[macOS updates] installing ${#installable[@]} update(s): ${installable[*]}"
  dialog_step "__osupdate" "active" "Installing ${#installable[@]} update(s)…"

  # Install only the specific non-CLT labels. Can take a while for big patches.
  local rc=0
  for l in "${installable[@]}"; do
    softwareupdate -i "$l" --agree-to-license --verbose >>"$LOG_FILE" 2>&1 || rc=$?
  done

  if [[ $restart_required -eq 1 ]]; then
    OS_RESTART_NEEDED=1
    dialog_step "__osupdate" "active" "Installed — restart required"
    log "[macOS updates] restart required to complete"
  else
    dialog_step "__osupdate" "active" "Installed"
  fi
  return $rc
}

work_aap() {
  # Deploy AAP by hand — the script's built-in "self-install when run outside
  # working folder" hook is only reached by certain flag combinations and
  # rejects --reset-defaults with a usage-error exit. Doing the deploy
  # ourselves is smaller, more reliable, and lets us skip the wall of debug
  # output AAP prints on first run. AAP's own state folders get created by
  # the LaunchDaemon on first fire.
  local aap_url="https://raw.githubusercontent.com/App-Auto-Patch/App-Auto-Patch/main/App-Auto-Patch-via-Dialog.zsh"
  local aap_folder="/Library/Management/AppAutoPatch"
  local aap_script="$aap_folder/App-Auto-Patch-via-Dialog.zsh"
  local aap_bin="/usr/local/bin/appautopatch"

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[App Auto-Patch] [dry-run] would download: $aap_url"
    log "[App Auto-Patch] [dry-run] would deploy $aap_script"
    log "[App Auto-Patch] [dry-run] would symlink $aap_bin"
    log "[App Auto-Patch] [dry-run] would deploy LaunchDaemon (Sundays 09:00)"
    dialog_step "__aap" "active" "Deploying (simulated)…"
    sleep 0.7
    return 0
  fi

  dialog_step "__aap" "active" "Downloading…"
  log "  → $aap_url"
  mkdir -p "$aap_folder"
  curl -fsSL --retry 3 -o "$aap_script" "$aap_url" || return 1
  chown root:wheel "$aap_script"
  chmod 755 "$aap_script"

  dialog_step "__aap" "active" "Linking /usr/local/bin/appautopatch…"
  mkdir -p /usr/local/bin
  ln -sf "$aap_script" "$aap_bin"
  [[ -x "$aap_bin" ]] || { warn "appautopatch symlink missing after ln"; return 1; }

  dialog_step "__aap" "active" "Scheduling weekly patch…"
  local plist=/Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
  # ProgramArguments MUST use the resolved script path, not the symlink at
  # /usr/local/bin/appautopatch — modern launchd (macOS 15+) refuses symlinks
  # here and errors with "Bootstrap failed: 5: Input/output error". Invoking
  # via /bin/zsh explicitly also avoids any exec-permission edge cases.
  cat > "$plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.github.mac-rebuild.appautopatch</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/zsh</string>
        <string>/Library/Management/AppAutoPatch/App-Auto-Patch-via-Dialog.zsh</string>
        <string>--workflow-install-now</string>
        <string>--interactiveMode=0</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key><integer>0</integer>
        <key>Hour</key><integer>9</integer>
        <key>Minute</key><integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>/var/log/appautopatch.out.log</string>
    <key>StandardErrorPath</key>
    <string>/var/log/appautopatch.err.log</string>
</dict>
</plist>
PLIST
  chown root:wheel "$plist"; chmod 644 "$plist"
  # If a stale bootstrap from a previous run is still registered, remove it
  # before bootstrapping the corrected plist.
  launchctl bootout system "$plist" 2>/dev/null || true
  launchctl bootstrap system "$plist" 2>>"$LOG_FILE" || \
    launchctl load -w "$plist" 2>>"$LOG_FILE" || \
    { warn "LaunchDaemon bootstrap failed — see $LOG_FILE"; return 1; }
}

# ─── Main loop ────────────────────────────────────────────────────────────────

trap 'log "Interrupted."; dialog_finish "cancelled" "Stopped — re-run to continue where you left off."; exit 130' INT TERM

cancelled=0
OS_RESTART_NEEDED=0
for label in "${STEP_LABELS[@]}"; do
  if dialog_cancelled; then cancelled=1; break; fi
  case "$label" in
    __claudecode)       run_step "$label" work_claudecode ;;
    __aiwrappers)       run_step "$label" work_aiwrappers ;;
    __defaults)         run_step "$label" work_defaults ;;
    __dock)             run_step "$label" work_dock ;;
    __defaultbrowser)   run_step "$label" work_defaultbrowser ;;
    __newfileservice)   run_step "$label" work_newfileservice ;;
    __updatelauncher)   run_step "$label" work_updatelauncher ;;
    __brewpackages)     run_step "$label" work_brewpackages ;;
    __ohmyposh)         run_step "$label" work_ohmyposh ;;
    __otherupdates)     run_step "$label" work_otherupdates ;;
    __updateallapps)    run_step "$label" work_updateallapps ;;
    __aap)              run_step "$label" work_aap ;;
    __osupdate)         run_step "$label" work_osupdate ;;
    *)                  run_step "$label" work_installomator ;;
  esac
  [[ $? -eq 99 ]] && { cancelled=1; break; }
done

# ─── Wrap up ──────────────────────────────────────────────────────────────────

if [[ $cancelled -eq 1 ]]; then
  log "════════════════════════════════════════════════════════"
  log " Cancelled. Re-run to continue where you left off."
  log "════════════════════════════════════════════════════════"
  dialog_finish "cancelled" "Cancelled. Re-run to continue where you left off — completed steps are remembered."
  exit 3
fi

# All steps done — reset state so a future re-run starts fresh.
if [[ $DRY_RUN -eq 0 ]]; then
  rm -f "$STATE_FILE"
fi

if [[ $DRY_RUN -eq 1 ]]; then
  log "════════════════════════════════════════════════════════"
  log " Dry run complete. Nothing on this Mac was changed."
  log "════════════════════════════════════════════════════════"
  dialog_finish "success" "Dry run complete — nothing changed."
elif [[ $UPDATE_ONLY -eq 1 ]]; then
  log "════════════════════════════════════════════════════════"
  log " Update check complete."
  [[ $OS_RESTART_NEEDED -eq 1 ]] && log " ⚠  Restart required to finish macOS updates."
  log "════════════════════════════════════════════════════════"
  if [[ $OS_RESTART_NEEDED -eq 1 ]]; then
    dialog_finish "success" "Everything up to date — restart to finish macOS updates."
  else
    dialog_finish "success" "Everything up to date."
  fi
else
  log "════════════════════════════════════════════════════════"
  log " mac-rebuild finished."
  [[ $OS_RESTART_NEEDED -eq 1 ]] && log " ⚠  Restart required to complete macOS updates."
  log "════════════════════════════════════════════════════════"
  if [[ $OS_RESTART_NEEDED -eq 1 ]]; then
    dialog_finish "success" "Your Mac is ready — please restart to finish macOS updates."
  else
    dialog_finish "success" "Your Mac is ready."
  fi
fi
