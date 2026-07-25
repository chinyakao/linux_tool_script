#!/usr/bin/env bash
set -e

# Print all stderr messages in red
exec 2> >(while IFS= read -r line; do
    printf '\033[31mERROR: %s\033[0m\n' "$line" >&2
done)

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    echo "This script must not be run as root." >&2
    exit 1
fi

# Check token argument
if [ -z "$1" ]; then
    echo "Missing required argument: token" >&2
    echo "Usage: $0 <token>" >&2
    exit 1
fi

token="$1"

echo "Updating apt package list..."
sudo apt update

echo "Installing ssh and tmux..."
sudo apt install ssh tmux -y

echo "Installing ngrok..."
sudo snap install ngrok -y

echo "Adding ngrok auth token..."
ngrok config add-authtoken "$token"

echo "Starting ngrok TCP tunnel on port 22..."
ngrok tcp 22
