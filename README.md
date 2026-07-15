# mac-rebuild

Fresh-Mac setup driven by [SwiftDialog](https://github.com/swiftDialog/swiftDialog), [Installomator](https://github.com/Installomator/Installomator), and [App Auto-Patch](https://github.com/App-Auto-Patch/AAP3) — the stack Jamf admins use to provision fleets, minus the MDM.

Runs unattended. Shows a real progress UI with per-app download/verify/install status. Keeps apps updated on a weekly schedule after install. Has a dry-run mode you can test with before touching anything.

## One-line install

On a fresh Mac, open Terminal and paste:

```sh
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JesseWebDotCom/macos-setup-scripts/main/bootstrap.sh)"
```

That's it. The bootstrap will:

1. Install Xcode Command Line Tools (brings `git`, `clang`, etc.).
2. Clone this repo to `~/mac-rebuild`.
3. Re-launch under `sudo` and run `setup.sh`.

## Dry-run mode

Preview the whole flow — real UI, no changes to what actually matters:

```sh
cd ~/mac-rebuild
sudo ./setup.sh --dry-run                # SwiftDialog UI, everything simulated
sudo ./setup.sh --dry-run --no-dialog    # text-only, skip SwiftDialog install
```

- SwiftDialog and Installomator are installed for real — they're the preview harness.
- **Nothing else is changed**: no apps installed, no defaults written, no LaunchDaemon deployed, no Claude Code, no App Auto-Patch.
- Installomator runs with `DEBUG=1` (its native dry-run — verifies labels/URLs, drives real-time dialog status, installs nothing).
- Log at `/var/log/mac-rebuild-dryrun.log`.

Use this to sanity-check a fresh apps.conf, verify labels resolve, or preview the UI on any Mac.

## What runs (in order)

| Step | How | Real-time status shown |
| --- | --- | --- |
| Xcode Command Line Tools | `bootstrap.sh` (before this script) | Terminal |
| SwiftDialog | Latest `.pkg` from GitHub release | Terminal |
| Installomator | Latest `.pkg` from GitHub release | Terminal |
| **Every app in `apps.conf`** | `Installomator <label>` per line | **Downloading → Verifying → Installing** per app, live in the dialog |
| Claude Code CLI | Anthropic's native installer (`claude.ai/install.sh`) | Dialog listitem |
| macOS defaults | ~30 `defaults write` commands, inline in `setup.sh` | Dialog listitem |
| App Auto-Patch | Latest `.pkg` + a weekly LaunchDaemon | Dialog listitem |

The dialog shows a checklist with one line per step. Each line updates in real time as it runs — thanks to Installomator's `DIALOG_LIST_ITEM_NAME` integration, you literally see "Downloading Firefox 143.0.1…" then "Verifying…" then "Installing…" then a green ✓.

## What's installed out of the box

Edit `apps.conf` before running to change this list.

- **Browsers**: Google Chrome, Firefox
- **Terminal**: Ghostty
- **AI**: Claude desktop, ChatGPT, Claude Code CLI
- **Media**: VLC, Plex (client)
- **Dev tools** (via Command Line Tools): `git`, `clang`, `make`, and friends

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

Native tiling doesn't do thirds/sixths, custom layouts, or session persistence. If you need those, uncomment `rectangle` in `apps.conf` — Rectangle is free, MIT-licensed, and does more than Magnet ($9.99) for zero cost.

## Weekly patching (App Auto-Patch)

After install, `/Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist` runs every **Sunday at 09:00** and calls `appautopatch --workflow-install-now --interactiveMode=0`. That silently updates every installed app that has an Installomator label — including apps you install later by hand.

To change the schedule, edit the plist's `StartCalendarInterval` (`Weekday`: 0=Sun, 1=Mon, … 6=Sat) and reload:

```sh
sudo launchctl unload /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
sudo launchctl load   /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
```

To trigger a patch run right now:

```sh
sudo appautopatch --workflow-install-now --interactiveMode=0
```

## Customizing

**Add or remove an app** — edit `apps.conf`. One [Installomator label](https://github.com/Installomator/Installomator/blob/main/Labels.txt) per line, `#` for comments.

**Change what defaults get set** — the settings all live in one `defaults_script` heredoc inside `setup.sh`. Nothing hidden in a helper file.

**Change the patch schedule** — the LaunchDaemon plist is written inline in `install_aap()` in `setup.sh`. Change `Weekday`/`Hour`/`Minute`.

**Run again later** — safe to re-run. Installomator, SwiftDialog, and AAP all no-op if already current. App Auto-Patch will keep everything current on its own.

## Manual usage (already have the repo)

```sh
cd ~/mac-rebuild
sudo ./setup.sh              # real run
./setup.sh --dry-run         # simulate
```

## Uninstalling

```sh
sudo launchctl unload /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
sudo rm /Library/LaunchDaemons/com.github.mac-rebuild.appautopatch.plist
sudo rm -rf /Library/Management/AppAutoPatch
sudo rm -rf /usr/local/Installomator
sudo rm /usr/local/bin/dialog
```

## Requirements

- macOS 13 Ventura or newer (SwiftDialog and Claude Code both require it; macOS 27 Golden Gate is fully supported)
- An admin account (you'll be prompted for your password once)
- Internet

## Why not Homebrew?

Homebrew is great for CLI tools you'll manage yourself. For "set my Mac up and keep it that way," Installomator + App Auto-Patch is a lot less babysitting: Installomator handles code-signed vendor packages directly, AAP updates them on a schedule without you running `brew upgrade`, and neither leaves stale `.app` bundles behind when a vendor changes their distribution.

The old scripts driving this were a lot of code to maintain and drifted quickly as apps and macOS changed. This version leans on tooling the Mac admin community actively maintains, so most drift now belongs to someone else.
