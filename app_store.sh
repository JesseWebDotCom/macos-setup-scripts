#!/bin/sh

# imports
SCRIPT_DIR="$(
    cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit
    pwd -P
)"
source "$SCRIPT_DIR/_shared.sh"
source "$SCRIPT_DIR/_progress.sh"

###############################################################################
# SETTINGS                                                                    #
###############################################################################

# Enable the WebKit Developer Tools in the Mac App Store
# defaults write com.apple.appstore WebKitDeveloperExtras -bool true

# Enable Debug Menu in the Mac App Store
# defaults write com.apple.appstore ShowDebugMenu -bool true

# Enable the automatic update check
defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true

# Check for software updates daily, not just once per week
defaults write com.apple.SoftwareUpdate ScheduleFrequency -int 1

# Download newly available updates in background
defaults write com.apple.SoftwareUpdate AutomaticDownload -int 1

# Install System data files & security updates
defaults write com.apple.SoftwareUpdate CriticalUpdateInstall -int 1

# Automatically download apps purchased on other Macs
defaults write com.apple.SoftwareUpdate ConfigDataInstall -int 1

# Turn on app auto-update
defaults write com.apple.commerce AutoUpdate -bool true

# Allow the App Store to reboot machine on macOS updates
defaults write com.apple.commerce AutoUpdateRestartRequired -bool true


###############################################################################
# INSTALLS                                                                    #
###############################################################################

# install mas-cli to install from the Mac App store
brew install mas

# install macos apps
bar_start

StuffToDo=( 
    1352778147 # Bitwarden
    497799835 # Xcode
    1153157709 # Speedtest
    1501308038 # Better Rename 11
    430798174 # HazeOver
    1160435653 # AutoMounter
    1295203466 # Microsoft Remote Desktop
    424389933 # Final Cut Pro
    443987910 # 1Password 6
    1432731683 # AdBlock Plus
    424390742 # Compressor
    409203825 # Numbers
    441258766 # Magnet
    1064959555 # New File Menu 
 )

TotalSteps=${#StuffToDo[@]}

for Stuff in ${StuffToDo[@]}; do
    set_title "Installing ${Stuff}..."
    echo_green "Installing ${Stuff}..."
    mas install ${Stuff}
    
    StepsDone=$((${StepsDone:-0}+1))
    bar_status_changed $StepsDone $TotalSteps
done
bar_stop

# close app store
killall 'App Store'

set_title "DONE"