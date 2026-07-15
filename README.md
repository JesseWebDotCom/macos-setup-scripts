# macos-setup-scripts

Fresh-Mac setup driven by [SwiftDialog](https://github.com/swiftDialog/swiftDialog), [Installomator](https://github.com/Installomator/Installomator), and [App Auto-Patch](https://github.com/App-Auto-Patch/AAP3) — the stack Jamf admins use to provision fleets, minus the MDM.

Paste one line into Terminal on a brand-new Mac and walk away. It installs your apps, sets ~30 sensible macOS defaults, wires up your shell, and leaves behind a weekly job that keeps everything patched. Runs unattended, shows a real progress UI with per-app download/verify/install status, remembers where it left off if interrupted, and has a dry-run mode you can test with before touching anything.

## One-line install

On a fresh Mac, open Terminal and paste:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JesseWebDotCom/macos-setup-scripts/main/bootstrap.sh)"
```

The bootstrap will:

1. Install Xcode Command Line Tools (brings `git`, `clang`, etc.).
2. Clone this repo to `~/mac-rebuild`.
3. Re-launch under `sudo` and run `setup.sh`.

That's it — the rest is automatic. You'll click through two Apple system prompts along the way (default-browser confirmation, and your password once).

---

## What it does, in order

A full setup runs these steps, each shown as a live line in the progress dialog:

| # | Step | What it does |
| --- | --- | --- |
| 1 | **Apps** (`apps.conf`) | Installs every Installomator label — Chrome, Firefox, Ghostty, Claude, ChatGPT, VLC, Plex, and more (full list below) |
| 2 | **Homebrew + packages** (`brew.conf`) | Installs Homebrew, then ~25 CLI tools and casks |
| 3 | **Oh My Posh** | Themed zsh prompt + Nerd Font, wired into Ghostty |
| 4 | **Claude Code CLI** | Anthropic's native self-updating installer |
| 5 | **AI shell wrappers** | `claude`/`clauded`/`codex`/`codexd` with color-themed terminals |
| 6 | **macOS defaults** | ~30 `defaults write` tweaks (Finder, Dock, keyboard, screenshots…) |
| 7 | **Dock cleanup** | Removes Apple's default clutter, pins Firefox |
| 8 | **Default browser** | Sets Firefox (you confirm the Apple prompt) |
| 9 | **New Text File** | One-click new-file creator for Finder |
| 10 | **Update Apps.app** | A double-clickable app to update everything later |
| 11 | **App Auto-Patch** | Weekly LaunchDaemon that keeps apps current |
| 12 | **Other updaters** | Mac App Store (`mas`) + Microsoft AutoUpdate |
| 13 | **macOS updates** | `softwareupdate` for pending system patches |

Each dialog line updates in real time — thanks to Installomator's `DIALOG_LIST_ITEM_NAME` integration you literally see "Downloading Firefox 143.0.1…" → "Verifying…" → "Installing…" → a green ✓.

---

## Installs

### Apps (via Installomator — `apps.conf`)

Edit `apps.conf` before running to change this list. One [Installomator label](https://github.com/Installomator/Installomator/blob/main/Labels.txt) per line.

| App | What it is |
| --- | --- |
| **Google Chrome** | Google's browser |
| **Firefox** | Mozilla's browser — also pinned in the Dock and set as default |
| **Ghostty** | Fast, GPU-accelerated terminal (configured with a Nerd Font below) |
| **Claude** | Anthropic's desktop app |
| **ChatGPT** | OpenAI's desktop app |
| **VLC** | Plays essentially any media file |
| **Plex** | Desktop client for a Plex media server |
| **Keka** | Opens RAR / 7z / rare archive formats macOS can't |
| **AltTab** | Windows-style Alt-Tab window switcher with previews |
| **Hazel** | Automated file & folder rules (watch a folder, act on new files) |
| **Tailscale** | Mesh VPN — reach your other machines from anywhere |
| **balenaEtcher** | Flash OS images to USB drives / SD cards |
| **SoundSource** | Per-app audio control & routing (Rogue Amoeba) |
| **Microsoft Windows App** | RDP client for Windows / Azure VMs / Windows 365 |

Commented-out extras you can enable in `apps.conf`: **Rectangle** (window manager — see the tiling note below).

### Homebrew packages (`brew.conf`)

Installs Homebrew itself, then these formulae and casks (with `brew shellenv` wired into `~/.zshrc` so they're immediately on your `PATH`):

- **Languages / runtimes** — `python` (3.13+), `uv` (Astral's fast Python installer + venv manager)
- **Prompt & fonts** — `oh-my-posh`, `font-meslo-lg-nerd-font`
- **AI CLIs** — `codex` (OpenAI Codex CLI)
- **Apps with broken Installomator labels (July 2026)** — `bartender` (menu-bar organizer), `tigervnc` (VNC client)
- **Media** — `ffmpeg`, `yt-dlp`, `imagemagick`
- **CLI quality-of-life** — `gh` (GitHub CLI), `jq` / `yq` (JSON/YAML), `ripgrep`, `fd`, `bat`, `eza`, `htop`, `tree`, `wget`, `mas` (Mac App Store CLI)

### Shell & developer tooling

- **Claude Code CLI** — installed via Anthropic's native installer and added to your `PATH` in `~/.zshrc` (it self-updates, so it's only downloaded once).
- **AI shell wrappers** — convenience functions in `~/.config/mac-rebuild/shell-ai.zsh`, sourced from `~/.zshrc`:
  - `claude` — Claude Code with a subtle warm (Gruvbox) terminal wash
  - `clauded` — bold-orange terminal + `claude --dangerously-skip-permissions` (unmistakable "danger mode")
  - `codex` — Codex with a subtle cool (Tokyo Night) terminal wash
  - `codexd` — bold-blue terminal + `codex --dangerously-bypass-approvals-and-sandbox`

  The terminal color always resets when the tool exits — even on Ctrl-C.
- **Oh My Posh prompt** — the `jandedobbeleer` theme wired into `~/.zshrc`, with Ghostty pointed at *MesloLGS Nerd Font Mono* so the prompt's icons and glyphs render correctly.

### Under-the-hood tooling

Installed automatically because the setup depends on it: **SwiftDialog** (the progress UI), **Installomator** (app installs), **App Auto-Patch** (weekly patching), **dockutil** (Dock edits), and **macadmins/default-browser** (the default-browser change).

---

## Configurations

The **~30 macOS defaults** (all in one `defaults_script` heredoc inside `setup.sh` — nothing hidden in helper files):

| Area | What changes |
| --- | --- |
| **Appearance** | Dark mode |
| **Finder** | Show hidden files & all extensions · path bar & status bar · list view by default · search the current folder (not the whole Mac) · folders sorted first · new windows open Home · no "are you sure?" on extension changes · expanded Save/Print panels |
| **Dock** | Auto-hide (fast 0.4s) · no recent apps · 42px tiles · scale minimize effect · minimize windows into the app icon |
| **Menu bar** | Battery icon **with percentage** |
| **Screenshots** | Saved as PNG to `~/Pictures/Screenshots` (not scattered on the Desktop) |
| **Keyboard** | Press-and-hold off (repeat a key instead of the accent popup) · fast key-repeat rate |
| **Trackpad** | Tap to click |
| **Window tiling** | Edge-drag tiling on · Option-key accelerator · margins between tiled windows |
| **Safari** | Develop menu + Web Inspector enabled |
| **TextEdit** | Opens in plain-text mode (no rich text) |
| **Time Machine** | Stop prompting to use every new disk as a backup |

Plus the non-`defaults` configuration steps:

- **Dock cleanup** — removes Maps, Photos, Games, and Reminders from the Dock (whatever Apple pinned), then pins Firefox after Safari.
- **Default browser** — sets Firefox as system default (macOS shows its own confirmation dialog; click "Use Firefox").
- **New Text File** — builds `/Applications/New Text File.app`. Drag it onto any Finder toolbar (Cmd-drag) for one-click new-file creation in the current folder — the free equivalent of a paid "new file here" utility.

---

## Features

- **Live progress UI** — SwiftDialog checklist, one line per step, updating in real time with each app's real download/verify/install phase and icon.
- **Dry-run mode** — preview the entire flow with zero changes to what matters (see below).
- **Resume-safe** — every completed step is recorded in `/var/db/mac-rebuild/completed.txt`. If you cancel or it's interrupted, re-running picks up exactly where it left off. `--reset` starts clean.
- **Idempotent** — safe to re-run anytime. Installomator, Homebrew, SwiftDialog, and every config step no-op if already current.
- **One-click updates later** — installs `/Applications/Update Apps.app`. Double-click it and you get the native password prompt, then the same dialog cycling through app + macOS updates (it runs `setup.sh --update` from a stable copy at `/usr/local/mac-rebuild`).
- **Weekly auto-patching** — a LaunchDaemon runs App Auto-Patch every **Sunday at 09:00**, silently updating every installed app that has an Installomator label — including apps you add by hand later.
- **Restart awareness** — if a macOS update needs a reboot, the final screen tells you (it never reboots out from under you).
- **Text-only fallback** — `--no-dialog` skips SwiftDialog for a plain-text run.

---

## Dry-run mode

Preview the whole flow — real UI, no changes to what actually matters:

```sh
cd ~/mac-rebuild
sudo ./setup.sh --dry-run                # SwiftDialog UI, everything simulated
sudo ./setup.sh --dry-run --no-dialog    # text-only, skip SwiftDialog install
```

- SwiftDialog and Installomator are installed for real — they're the preview harness.
- **Nothing else is changed**: no apps installed, no defaults written, no LaunchDaemon deployed, no Claude Code, no App Auto-Patch.
- Installomator runs with `DEBUG=1` (its native dry-run — verifies labels/URLs, drives the real-time dialog status, installs nothing).
- Log at `/var/log/mac-rebuild-dryrun.log`.

Use this to sanity-check a fresh `apps.conf`, verify labels resolve, or preview the UI on any Mac.

---

## Keeping your Mac current

Three layers, all automatic after setup:

1. **Weekly** — App Auto-Patch patches every labelled app each Sunday 09:00.
2. **On demand** — double-click **Update Apps.app** (or `sudo ./setup.sh --update`) to check apps + macOS right now.
3. **Self-updating** — Claude Code and a few apps update themselves.

To change the weekly schedule, edit `StartCalendarInterval` in the LaunchDaemon (`Weekday`: 0=Sun … 6=Sat) and reload:

```sh
sudo launchctl unload /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
sudo launchctl load   /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
```

Trigger a patch run right now:

```sh
sudo appautopatch --workflow-install-now --interactiveMode=0
```

---

## macOS 27 Golden Gate — do I need Magnet or Rectangle?

Short answer: **no, unless you want thirds or saved layouts.**

macOS 15 Sequoia introduced native window tiling and 26 Tahoe / 27 Golden Gate kept it. Built-in shortcuts:

| Action | Shortcut |
| --- | --- |
| Fill screen | Fn-Control-F |
| Center | Fn-Control-C |
| Left / right / top / bottom half | Fn-Control-Arrow |
| Two-window arrangements (L&R, T&B, etc.) | Fn-Control-Shift-Arrow |
| Quarter arrangements | Fn-Control-Option-Shift-Arrow |
| Restore previous size | Fn-Control-R |

(The setup also enables edge-drag tiling and tiled-window margins via defaults.) Native tiling doesn't do thirds/sixths, custom layouts, or session persistence. If you need those, uncomment `rectangle` in `apps.conf` — Rectangle is free, MIT-licensed, and does more than Magnet ($9.99) for zero cost.

---

## Customizing

- **Add or remove an app** — edit `apps.conf`. One [Installomator label](https://github.com/Installomator/Installomator/blob/main/Labels.txt) per line, `#` for comments.
- **Add or remove a CLI tool** — edit `brew.conf`. One Homebrew formula/cask per line.
- **Change what defaults get set** — the settings all live in one `defaults_script` heredoc inside `setup.sh`.
- **Change the patch schedule** — the LaunchDaemon plist is written inline in `work_aap()` in `setup.sh`. Change `Weekday`/`Hour`/`Minute`.
- **Run again later** — safe to re-run; everything no-ops if current.

## Manual usage (already have the repo)

```sh
cd ~/mac-rebuild
sudo ./setup.sh              # full setup
sudo ./setup.sh --update     # apps + macOS updates only
sudo ./setup.sh --dry-run    # simulate
sudo ./setup.sh --reset      # clear saved progress, start over
sudo ./setup.sh --help       # all flags
```

**Files & paths** (internal identifiers use the project's `mac-rebuild` codename):

| Path | Purpose |
| --- | --- |
| `~/mac-rebuild` | Clone location |
| `/var/log/mac-rebuild.log` | Full log of every run |
| `/var/db/mac-rebuild/completed.txt` | Completed-steps state (resume) |
| `/usr/local/mac-rebuild/` | Stable copy used by Update Apps.app |
| `/Applications/Update Apps.app` | Double-click updater |

## Uninstalling

```sh
sudo launchctl unload /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
sudo rm /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
sudo rm -rf /Library/Management/AppAutoPatch
sudo rm -rf /usr/local/Installomator /usr/local/mac-rebuild
sudo rm /usr/local/bin/dialog /usr/local/bin/appautopatch
sudo rm -rf "/Applications/Update Apps.app" "/Applications/New Text File.app"
```

## Requirements

- macOS 13 Ventura or newer (SwiftDialog and Claude Code both require it; macOS 27 Golden Gate is fully supported)
- An admin account (you'll be prompted for your password once)
- Internet

## Why not Homebrew for everything?

Homebrew is great for CLI tools you'll manage yourself — and this setup uses it for exactly that (`brew.conf`). For GUI apps and "set my Mac up and keep it that way," Installomator + App Auto-Patch is a lot less babysitting: Installomator handles code-signed vendor packages directly, AAP updates them on a schedule without you running `brew upgrade`, and neither leaves stale `.app` bundles behind when a vendor changes their distribution.

The old scripts driving this ([v1.0.0](https://github.com/JesseWebDotCom/macos-setup-scripts/releases/tag/v1.0.0)) were a lot of code to maintain and drifted quickly as apps and macOS changed. This version leans on tooling the Mac admin community actively maintains, so most drift now belongs to someone else.
