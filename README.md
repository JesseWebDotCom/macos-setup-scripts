# macos-setup-scripts
Save yourself hours with this automated configuration, optimization, app install, and software updating on a freshly built MacOS.

## Highlights
A few highlights of these scripts:
* Changes many common configurations (ex. enabling finder list view, setting dark mode, setting up hot corners)
* Optimizes (ex. increases bluetooth audio quality)
* Cleans up the dock
* Fixes many MacOS annoyances (ex. expands save/print dialogs by default)
* Automates the installation of applications from the App Store
* Automates the installation of homebrew and any desired applications
* Automates patching of the OS, app store apps, home brew apps, and Microsoft Office

## Prerequisites
* Perform a clean OS install
* Run `chmod +x *.sh` in the directory containing all the scripts
* Edit git.sh to use your git username and email address (or comment out running ./git.sh in the setup.sh script)
* Review all other scripts and make changes as needed (you likely do not use all the same apps, configurations, etc that I use)

## Usage
```
./setup.sh
```

Note: You will be prompted for your local admin password and app store password when needed.

## Manual

These are manual steps I haven't automated yet.

* Configure bitwarden
* Sign into app store
* Discord - Login, start, and configure start as login
* iterm2
    * set font and size
    * make default terminal
    * install shell
* little snitch license and config
* switft bar
    * got internet plugin
    * launch at login
* magnet
    * permissions
    * launch at login
* hazover
    * start at login
    * animation off
* keka
    * finder integration
    * set as default decompressor
* new file menu
    * finder integration
    * launch at login
    * do not show in menu bar
    * do not show menu for files
* add network locations in finder
* enable safari extensions
* set software updates to automatic
* use apple watch to unlock mac
* vlc
    * enable metadata retrieval
* plex
    * login
* remote desktop
    * configure
* Apple music
* pick screensaver
* hot corner lock screen
* app store app - better battery status
* install office
* install adobe apps
* run 3rdparty.sh

## TODOs
* Make script easier to customize (ex. a config file for settings like git username/email)
* Standardize sudo calls
* Add more logging/progress

## Credits

A lot of content here came from numerous web searches and sites, a lot of which has overlapping or duplicate code. There is no clear way to credit the true authors.