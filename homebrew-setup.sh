# Check for Homebrew, and then install it
if test ! "$(which brew)"; then
    echo "Installing homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    echo "Homebrew installed successfully"
else
    echo "Homebrew already installed!"
fi

echo Installing XCode Command Line Tools...
# install Xcode command line form terminal
xcode-select --install

# Updating Homebrew.
echo "Updating Homebrew..."
rm -rf $(brew --repo homebrew/core)
brew tap homebrew/core
brew update

Echo Disabling analytics...
brew analytics off