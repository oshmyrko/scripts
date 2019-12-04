#!/bin/bash
set -e # Exit on error
set -u # Treat unset variables as error
set -o pipefail

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<-EOF
Usage: $0 [OPTION]...
   or: $0 --s3-path
   or: $0 --s3-path --debug
   or: $0 -h|--help

Sync SSH public keys from S3 and create/delete user accounts basing on key name.

Options:
    -s, --s3-path [path]    S3 path to public keys (e.g. mybucket/ssh-keys).
    -d, --debug             enable bash debugging.
EOF
}

# Function for displaying message with prepended date
echo_date_message() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] - $1"
}

# ------------------------------------------------------------------------------
# Parse options and their arguments
# ------------------------------------------------------------------------------
# If no options, print usage and exit
if [ $# -eq 0 ]; then
    usage
    exit 2
fi

while [ $# -ne 0 ]; do
    arg="$1"
    shift
    case "$arg" in
        -h|--help)     usage;         exit 0 ;;
        -s|--s3-path)  s3_path=$1;    shift  ;;
        -d|--debug)    set -o xtrace         ;;
        *)             usage;         exit 1 ;;
    esac
done

# Directory to store
tmp_dir=/tmp/ssh-keys

# Sync public keys from S3 bucket to local directory
if (aws s3 sync s3://${s3_path}   \
                ${tmp_dir}        \
                --exclude "*"     \
                --include "*.pub" \
                --delete          \
                --no-progress     \
                | grep -Ewq '^download|delete'); then
    echo_date_message 'Starting...'
else
    echo_date_message 'No keys to update.'
    # TODO: delete manually created users even if no key changes
    exit 0
fi

# List of public keys
keys=$(ls ${tmp_dir})

# Create users and add or update their public keys
for key in ${keys}; do
    username=${key%.pub}

    # Check if username is valid
    if ! [[ "${username}" =~ ^[a-z][-a-z0-9.]*$ ]]; then
        echo_date_message "Skip ${username} user. The name is not valid."
        # Skip the key and proceed with the next one
        continue
    fi

    # Create user if not exists, but its public key is present
    if ! (cut -d: -f1 /etc/passwd | grep -qx ${username}); then
        /usr/sbin/useradd -m -s /bin/bash -G wheel ${username}
        mkdir -m 700 /home/${username}/.ssh
        echo_date_message "${username} account was created."

        cp -u ${tmp_dir}/${key} /home/${username}/.ssh/authorized_keys
        chown -R ${username}:${username} /home/${username}/.ssh
        echo_date_message "${username} public key was added."
    # Update user's public key in case it was changed (comparison shows changes)
    elif ! (cmp -s ${tmp_dir}/${key} /home/${username}/.ssh/authorized_keys); then
        cp -u ${tmp_dir}/${key} /home/${username}/.ssh/authorized_keys
        chown -R ${username}:${username} /home/${username}/.ssh
        echo_date_message "${username} public key was updated."
    fi
done

# List of local users (excluding ec2-user, centos and ubuntu)
local_users=$(ls /home | grep -Evw "ec2-user|centos|ubuntu")

# Delete user in case its public key was deleted (nonexistent)
for local_user in ${local_users}; do
    if [ ! -f ${tmp_dir}/${local_user}.pub ]; then
        /usr/sbin/userdel -rf ${local_user}
        echo_date_message "${local_user} account was deleted."
    fi
done

echo_date_message 'Finished.'
