#!/usr/bin/env bash
set -e

# Print all stderr messages in red
exec 2> >(while IFS= read -r line; do
    printf '\033[31mERROR: %s\033[0m\n' "$line" >&2
done)

usage() {
    echo "Usage: $0 [-r remote_addr] <token>" >&2
    echo "Example: $0 your_ngrok_token" >&2
    echo "Example: $0 -r 1.tcp.ngrok.io:23456 your_ngrok_token" >&2
}

remote_addr=""

# Parse optional arguments
while getopts ":r:h" opt; do
    case "$opt" in
        r)
            remote_addr="$OPTARG"
            ;;
        h)
            usage
            exit 0
            ;;
        :)
            echo "Option -$OPTARG requires an argument." >&2
            usage
            exit 1
            ;;
        \?)
            echo "Invalid option: -$OPTARG" >&2
            usage
            exit 1
            ;;
    esac
done

shift $((OPTIND - 1))

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    echo "This script must not be run as root." >&2
    exit 1
fi

# Check token argument
if [ -z "${1:-}" ]; then
    echo "Missing required argument: token" >&2
    usage
    exit 1
fi

token="$1"

echo "Updating apt package list..."
sudo apt update

echo "Installing ssh and tmux..."
sudo apt install ssh tmux -y

echo "Installing ngrok..."
sudo snap install ngrok

echo "Adding ngrok auth token..."
ngrok config add-authtoken "$token"

echo "Starting ngrok TCP tunnel on port 22..."

if [ -n "$remote_addr" ]; then
    echo "Using remote address: $remote_addr"
    ngrok tcp --remote-addr="$remote_addr" 22
else
    ngrok tcp 22
fi
