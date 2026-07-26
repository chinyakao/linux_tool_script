#!/usr/bin/env bash
set -e

# Print all stderr messages in red
exec 2> >(while IFS= read -r line; do
    printf '\033[31mERROR: %s\033[0m\n' "$line" >&2
done)

usage() {
    echo "Usage: $0 [-r ngrok_url] [-l launchpad_id] <token>" >&2
    echo "Example: $0 your_ngrok_token" >&2
    echo "Example: $0 -r tcp://1.tcp.ngrok.io:23456 your_ngrok_token" >&2
    echo "Example: $0 -l hugh712 your_ngrok_token" >&2
    echo "Example: $0 -l hugh712 -r tcp://1.tcp.ngrok.io:23456 your_ngrok_token" >&2
}

ngrok_url=""
launchpad_id=""
token=""

# Parse arguments, order-independent
while [ "$#" -gt 0 ]; do
    case "$1" in
        -r)
            if [ -z "${2:-}" ]; then
                echo "Option -r requires an ngrok URL." >&2
                usage
                exit 1
            fi
            ngrok_url="$2"
            shift 2
            ;;
        -l)
            if [ -z "${2:-}" ]; then
                echo "Option -l requires a Launchpad ID." >&2
                usage
                exit 1
            fi
            launchpad_id="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            usage
            exit 1
            ;;
        *)
            if [ -z "$token" ]; then
                token="$1"
                shift
            else
                echo "Unexpected argument: $1" >&2
                usage
                exit 1
            fi
            ;;
    esac
done

# Check if running as root
if [ "$(id -u)" -eq 0 ]; then
    echo "This script must not be run as root." >&2
    exit 1
fi

# Check token argument
if [ -z "$token" ]; then
    echo "Missing required argument: token" >&2
    usage
    exit 1
fi

echo "Updating apt package list..."
sudo apt update

echo "Installing ssh, tmux and curl..."
sudo apt install ssh tmux curl -y

# Install ngrok only if not installed
if command -v ngrok >/dev/null 2>&1; then
    echo "ngrok is already installed. Skipping installation."
else
    echo "Installing ngrok..."
    sudo snap install ngrok
fi

if [ -n "$launchpad_id" ]; then
    echo "Importing SSH public keys from Launchpad account: $launchpad_id"

    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"

    launchpad_keys_url="https://launchpad.net/~${launchpad_id}/+sshkeys"

    keys="$(curl -fsSL "$launchpad_keys_url")"

    if [ -z "$keys" ]; then
        echo "No SSH public keys found from Launchpad account: $launchpad_id" >&2
        exit 1
    fi

    touch "$HOME/.ssh/authorized_keys"
    chmod 600 "$HOME/.ssh/authorized_keys"

    # Remove old block if this script was run before
    sed -i '/# BEGIN NGROK_REMOTE_SUPPORT_LAUNCHPAD_KEYS/,/# END NGROK_REMOTE_SUPPORT_LAUNCHPAD_KEYS/d' "$HOME/.ssh/authorized_keys"

    {
        echo "# BEGIN NGROK_REMOTE_SUPPORT_LAUNCHPAD_KEYS"
        echo "$keys"
        echo "# END NGROK_REMOTE_SUPPORT_LAUNCHPAD_KEYS"
    } >> "$HOME/.ssh/authorized_keys"

    chmod 600 "$HOME/.ssh/authorized_keys"

    echo "Launchpad SSH public keys imported into:"
    echo "$HOME/.ssh/authorized_keys"
fi

echo "Adding ngrok auth token..."
ngrok config add-authtoken "$token"

echo "Starting ngrok TCP tunnel on port 22..."

if [ -n "$ngrok_url" ]; then
    echo "Using ngrok URL: $ngrok_url"
    ngrok tcp --url="$ngrok_url" 22
else
    ngrok tcp 22
fi
