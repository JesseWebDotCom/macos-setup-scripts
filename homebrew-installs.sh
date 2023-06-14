# https://formulae.brew.sh

# imports
SCRIPT_DIR="$(
    cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit
    pwd -P
)"
source "$SCRIPT_DIR/_shared.sh"
source "$SCRIPT_DIR/_progress.sh"
bar_start

StuffToDo=( 
    iterm2
    git
    keka
    discord
    disk-inventory-x
    wget
    losslesscut
    docker
    ffmpeg
    google-chrome
    makemkv
    visual-studio-code
    vlc
    zoom
    teamviewer
    plex
    little-snitch
    swiftbar    
    raspberry-pi-imager
    musicbrainz-picard
    balenaetcher
    vnc-viewer
    screens   
 )

TotalSteps=${#StuffToDo[@]}

for Stuff in ${StuffToDo[@]}; do
    set_title "Installing ${Stuff}..."
    echo_green "Installing ${Stuff}..."
    brew install --cask ${Stuff}
    
    StepsDone=$((${StepsDone:-0}+1))
    bar_status_changed $StepsDone $TotalSteps
done
bar_stop

# Upgrade any already-installed formulae.
echo_green "Upgrading Homebrew..."
brew upgrade

set_title "DONE"