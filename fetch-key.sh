#!/usr/bin/env bash

# ==============================================================================
# FETCH THE SSH LOGIN KEY FROM THE SERVER (RUN ON YOUR COMPUTER, NOT THE SERVER)
# Copies the .pem that bootstrap.sh created into ~/keys and sets chmod 600.
# It never deletes the server copy. Delete that on the server, at the bootstrap
# prompt, after you have tested the new login.
# ==============================================================================

set -euo pipefail
umask 077

LOCAL_KEY_DIR="$HOME/keys"
login_key=""
port="22"

usage() {
    echo "Usage: $0 [-i LOGIN_KEY] [-p PORT] USER@HOST REMOTE_PATH" >&2
    echo "Example: $0 -i ~/Downloads/provider-key.pem root@203.0.113.10 /root/admin-host.pem" >&2
    exit 1
}

while getopts "i:p:h" opt; do
    case "$opt" in
        i) login_key="$OPTARG" ;;
        p) port="$OPTARG" ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ "$#" -eq 2 ] || usage

target="$1"
remote_path="$2"
name="$(basename "$remote_path")"
if ! [[ "$name" =~ ^[A-Za-z0-9._-]+\.pem$ ]]; then
    echo "The remote file must be a .pem file with a plain name, got: $remote_path" >&2
    exit 1
fi
if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo "Port must be a number, got: $port" >&2
    exit 1
fi

scp_opts=(-P "$port")
if [ -n "$login_key" ]; then
    scp_opts+=(-i "$login_key" -o IdentitiesOnly=yes)
fi

mkdir -p "$LOCAL_KEY_DIR"
chmod 700 "$LOCAL_KEY_DIR"
local_file="$LOCAL_KEY_DIR/$name"

if [ -e "$local_file" ]; then
    read -r -p "$local_file already exists. Overwrite it? (y/N): " answer
    if ! [[ "$answer" =~ ^[Yy]$ ]]; then
        echo "Kept the existing file."
        exit 0
    fi
fi

echo "Copying $target:$remote_path to $local_file ..."
scp "${scp_opts[@]}" "$target:$remote_path" "$local_file"
chmod 600 "$local_file"

if ! ssh-keygen -y -f "$local_file" >/dev/null 2>&1; then
    rm -f "$local_file"
    echo "The downloaded file is not a valid SSH key. Nothing was kept." >&2
    exit 1
fi

echo "Saved: $local_file"
echo "Next: test the login from a new terminal, then type 'delete' at the server prompt."
