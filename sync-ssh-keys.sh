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
   or: $0 --s3-path PATH
   or: $0 --s3-path PATH --debug
   or: $0 -h|--help

Sync SSH public keys from S3 and create/delete user accounts basing on key name.

Options:
    -s, --s3-path [path]    S3 path to public keys (e.g. mybucket/ssh-keys).
    -d, --debug             enable bash debugging.
EOF
}

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
# Temporary directory to download public keys
TEMP_DIR=/tmp/ssh-keys

# ------------------------------------------------------------------------------
# Functions
# ------------------------------------------------------------------------------
# Log message with prepended date
log_info() {
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')]: $1"
}

create_users_with_keys() {
    # List of public keys
    local keys=$(ls ${TEMP_DIR})
    # Create users and add or update their public keys
    for key in ${keys}; do
        username=${key%.pub}

        # Check if username is valid
        if ! [[ "${username}" =~ ^[a-z][-a-z0-9.]*$ ]]; then
            log_info "Skip ${username} user. The name is not valid."
            # Skip the key and proceed with the next one
            continue
        fi

        # Create user if not exists, but its public key is present
        if ! (id -u ${username} &> /dev/null); then
            useradd -m -s /bin/bash -G wheel ${username}
            mkdir -m 700 /home/${username}/.ssh
            log_info "${username} account was created."
    
            cp -u ${TEMP_DIR}/${key} /home/${username}/.ssh/authorized_keys
            chown -R ${username}:${username} /home/${username}/.ssh
            log_info "${username} public key was added."
        # Update user's public key in case it was changed (comparison shows changes)
        elif ! (cmp -s ${TEMP_DIR}/${key} /home/${username}/.ssh/authorized_keys); then
            cp -u ${TEMP_DIR}/${key} /home/${username}/.ssh/authorized_keys
            chown -R ${username}:${username} /home/${username}/.ssh
            log_info "${username} public key was updated."
        fi
    done
}

# Delete user in case its public key was deleted
delete_users_without_keys() {
    # List of local users (excluding ec2-user, centos and ubuntu)
    local local_users=$(ls /home/ | grep -Evw "ec2-user|centos|ubuntu")

    for local_user in ${local_users}; do
        if [ ! -f "${TEMP_DIR}/${local_user}.pub" ]; then
            userdel -rf ${local_user}
            log_info "${local_user} account was deleted."
        fi
    done
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

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
log_info "Starting..."

# Sync public keys from S3 bucket to local directory
if (aws s3 sync s3://${s3_path}   \
                ${TEMP_DIR}       \
                --exclude "*"     \
                --include "*.pub" \
                --delete          \
                --no-progress     \
                | grep -Ewq '^download|delete'); then
    create_users_with_keys
    delete_users_without_keys
else
    # Delete manually created users
    delete_users_without_keys
fi

log_info "Finished in ${SECONDS} sec."
