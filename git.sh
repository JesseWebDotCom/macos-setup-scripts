# imports
SCRIPT_DIR="$(
    cd -- "$(dirname "$0")" >/dev/null 2>&1 || exit
    pwd -P
)"
source "$SCRIPT_DIR/_shared.sh"

echo_green "Configuring Git..."
git config --global user.name "Jesse Torres"
git config --global user.email 20848952+JesseWebDotCom@users.noreply.github.com
