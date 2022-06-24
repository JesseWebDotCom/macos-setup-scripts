# MENU BAR
# ------------------------------------------------------------------------------

# Menu bar: disable transparency
defaults write NSGlobalDomain AppleEnableMenuBarTransparency -bool false

# Menu bar: show remaining battery time (on pre-10.8); hide percentage
defaults write com.apple.menuextra.battery ShowPercent -string "NO"
defaults write com.apple.menuextra.battery ShowTime -string "YES"

# Menu bar: hide/show icons
defaults write com.apple.systemuiserver menuExtras ' 
( 
    "/System/Library/CoreServices/Menu Extras/Volume.menu", 
    "/System/Library/CoreServices/Menu Extras/AirPort.menu", 
    "/System/Library/CoreServices/Menu Extras/Battery.menu", 
    "/System/Library/CoreServices/Menu Extras/Bluetooth.menu", 
    "/System/Library/CoreServices/Menu Extras/Clock.menu" 
)' 
killall SystemUIServer 

# Clock
defaults write com.apple.menuextra.clock DateFormat -string "EEE d MMMh:mm:ss"
defaults write com.apple.menuextra.clock FlashDateSeparators -int 0
defaults write com.apple.menuextra.clock IsAnalog -int 0

###############################################################################
# Dock, Dashboard, and hot corners                                            #
###############################################################################

# Enable highlight hover effect for the grid view of a stack (Dock)
defaults write com.apple.dock mouse-over-hilite-stack -bool true

# Set the icon size of Dock items
defaults write com.apple.dock tilesize -int 36

# Set the location of the dock
defaults write com.apple.dock orientation -string bottom

# Set the icon magnification size of Dock items
defaults write com.apple.dock largesize -int 69

# Enable dock magnification
defaults write com.apple.dock magnification -bool true

# Change minimize/maximize window effect
defaults write com.apple.dock mineffect -string "scale"

# Minimize windows into their application’s icon
defaults write com.apple.dock minimize-to-application -bool true

# Enable spring loading for all Dock items
defaults write com.apple.dock enable-spring-load-actions-on-all-items -bool true

# Show indicator lights for open applications in the Dock
defaults write com.apple.dock show-process-indicators -bool true

# Wipe all (default) app icons from the Dock
# This is only really useful when setting up a new Mac, or if you don’t use
# the Dock to launch apps.
#defaults write com.apple.dock persistent-apps -array

# Show only open applications in the Dock
#defaults write com.apple.dock static-only -bool true

# Don’t animate opening applications from the Dock
defaults write com.apple.dock launchanim -bool false

# Speed up Mission Control animations
defaults write com.apple.dock expose-animation-duration -float 0.1

# Don’t group windows by application in Mission Control
# (i.e. use the old Exposé behavior instead)
defaults write com.apple.dock expose-group-by-app -bool false

# Disable Dashboard
defaults write com.apple.dashboard mcx-disabled -bool true

# Don’t show Dashboard as a Space
defaults write com.apple.dock dashboard-in-overlay -bool true

# Don’t automatically rearrange Spaces based on most recent use
defaults write com.apple.dock mru-spaces -bool false

# Remove the auto-hiding Dock delay
defaults write com.apple.dock autohide-delay -float 0
# Remove the animation when hiding/showing the Dock
defaults write com.apple.dock autohide-time-modifier -float 0

# Automatically hide and show the Dock
defaults write com.apple.dock autohide -bool false

# Make Dock icons of hidden applications translucent
defaults write com.apple.dock showhidden -bool true

# Don’t show recent applications in Dock
defaults write com.apple.dock show-recents -bool false

# Disable the Launchpad gesture (pinch with thumb and three fingers)
#defaults write com.apple.dock showLaunchpadGestureEnabled -int 0

# Reset Launchpad, but keep the desktop wallpaper intact
find "${HOME}/Library/Application Support/Dock" -name "*-*.db" -maxdepth 1 -delete

# Add a spacer to the left side of the Dock (where the applications are)
#defaults write com.apple.dock persistent-apps -array-add '{tile-data={}; tile-type="spacer-tile";}'
# Add a spacer to the right side of the Dock (where the Trash is)
#defaults write com.apple.dock persistent-others -array-add '{tile-data={}; tile-type="spacer-tile";}'

# Hot corners
# Possible values:
#  0: no-op
#  2: Mission Control
#  3: Show application windows
#  4: Desktop
#  5: Start screen saver
#  6: Disable screen saver
#  7: Dashboard
# 10: Put display to sleep
# 11: Launchpad
# 12: Notification Center
# 13: Lock Screen
# Top left screen corner → Mission Control
defaults write com.apple.dock wvous-tl-corner -int 2
defaults write com.apple.dock wvous-tl-modifier -int 0
# Top right screen corner → Desktop
defaults write com.apple.dock wvous-tr-corner -int 4
defaults write com.apple.dock wvous-tr-modifier -int 0
# Bottom left screen corner → Start screen saver
defaults write com.apple.dock wvous-bl-corner -int 5
defaults write com.apple.dock wvous-bl-modifier -int 0



# ADD / REMOVE DOCK ITEMS
# use fork until official is updated to support python3
# brew install dockutil
brew install --cask hpedrorodrigues/tools/dockutil

# remove items
dockutil --remove 'Maps' --no-restart
dockutil --remove 'Photos' --no-restart
dockutil --remove 'News' --no-restart
dockutil --remove 'Launchpad' --no-restart
dockutil --remove 'Downloads' --no-restart
dockutil --remove 'TV' --no-restart

# add items
dockutil --add '/Applications' --view grid --display folder --sort name  --section others --before 'Trash' --no-restart
dockutil --add '~/Downloads' --view list --display folder --sort dateadded --section others --before 'Trash' --no-restart
dockutil --add "/Applications/Visual Studio Code.app" --after 'Safari' --no-restart

# restart dock
killall Dock