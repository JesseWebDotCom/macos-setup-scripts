#!/bin/sh

set_title () {
   echo "\033]0;OSX SETUP: $1\007"
}

echo_green () {
    GREEN='\033[32m' # Green
    CLEAR='\033[0m'  # Clear color and formatting
    echo "${GREEN}$1${CLEAR}"
}