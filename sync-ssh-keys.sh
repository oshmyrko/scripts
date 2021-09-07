#!/bin/bash
set -e # Exit on error
set -u # Treat unset variables as error
set -o pipefail

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat <<-EOF
Usage: $0 [OPTION]... S3_PATH

Sync SSH public keys from S3 and create/delete user accounts basing on key name.
S3 path should be specified as 'bucket/dir'.

Options:
    -h, --help      print usage.
    -c, --cronjob   create cronjob to sync keys and script.
    -d, --debug     enable bash debugging (verbose).
    -s, --sudoers   add sudoers config to allow people in group wheel to run all
                    commands.

To create a cronjob, add sudoers config and sync the keys, use the following
command:
    $0 -cs bucket/dir1/dir2

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
    echo -e "[$(date '+%Y-%m-%d %H:%M:%S')]: $@"
}

# Sync public keys from S3 bucket to local directory
sync_keys() {
    # --exact-timestamps: https://github.com/aws/aws-cli/issues/3273
    aws s3 sync s3://${S3_PATH} ${TEMP_DIR} \
        --exclude "*"      \
        --include "*.pub"  \
        --exact-timestamps \
        --no-progress      \
        --delete
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

        # Create user if it does not exist
        if ! (id -u ${username} &> /dev/null); then
            useradd -m -s /bin/bash -G wheel ${username}
            mkdir -m 700 /home/${username}/.ssh
            log_info "${username} account was created."
        fi

        # Copy user's public key in case it is absent or changed
        case "$(cmp -s ${TEMP_DIR}/${key} /home/${username}/.ssh/authorized_keys; echo $?)" in
            1|2) install -o ${username} -g wheel -m 600 \
                    ${TEMP_DIR}/${key} /home/${username}/.ssh/authorized_keys ;;&
            2)   log_info "${username} public key was added."                 ;;
            1)   log_info "${username} public key was updated."               ;;
           #*)   log_info "${username} public key left untouched."            ;;
        esac
    done
}

# Delete user in case its public key was deleted
delete_users_without_keys() {
    # List of local users (excluding default user)
    # TODO: Consider deleting users whose id > 1000
    local local_users=$(ls /home/ | grep -Evw "$(id -nu 1000)|ec2-user|centos|ubuntu")

    for local_user in ${local_users}; do
        if [ ! -f "${TEMP_DIR}/${local_user}.pub" ]; then
            userdel -rf ${local_user}
            log_info "${local_user} account was deleted."
        fi
    done
}

cronjob() {
    local script_name=$(basename $0)
    local script_dir=$(dirname $(realpath $0))
    local log_path=/var/log/${script_name%.*}.log

    cat <<-EOF > /etc/cron.d/${script_name%.*}
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/root/bin
SHELL=/bin/bash

# Sync SSH keys every hour
0 * * * * root ${script_name} ${S3_PATH} &>> ${log_path}

# Sync script daily after midnight
5 0 * * * root aws s3 cp s3://${S3_PATH}/${script_name} ${script_dir} --no-progress &>> ${log_path}
6 0 * * * root chmod 700 $(realpath $0)
EOF

    log_info "Cronjob added."
}

# Allow people in group wheel to run all commands
sudoers() {
    groupadd --force wheel
    cat <<-EOF > /etc/sudoers.d/10-wheel-users
# Allows people in group wheel to run all commands
%wheel ALL=(ALL) NOPASSWD: ALL
EOF
    chmod 440 /etc/sudoers.d/10-wheel-users

    log_info "Sudoers config added."
}

# ------------------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------------------
# If no arguments, print usage and exit
if [ $# -eq 0 ]; then
    usage
    exit 2
fi

# Parse arguments to get options and separate them from script parameters ($@)
PARSED_ARGS=$(getopt --name "$(basename $0)" \
                     --options cdhs \
                     --longoptions help,cronjob,debug,sudoers -- "$@")
# Reset script arguments to the parsed ones
eval set -- "${PARSED_ARGS}"

CRONJOB=false
DEBUG=false
SUDOERS=false

while [ $# -ne 0 ]; do
    case "$1" in
        -h | --help    ) usage;        exit 0 ;;
        -c | --cronjob ) CRONJOB=true; shift  ;;
        -d | --debug   ) DEBUG=true;   shift  ;;
        -s | --sudoers ) SUDOERS=true; shift  ;;
        --             ) shift;        break  ;;
        *              ) break                ;;
    esac
done

# Handle non-option arguments
if [ $# -ne 1 ]; then
    echo -e "$(basename $0): a single S3 path is required (e.g. bucket/dir)"
    exit 1
else
    S3_PATH="$@"
fi

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
if [ "${DEBUG}"   = true ]; then set -o xtrace; fi
if [ "${CRONJOB}" = true ]; then cronjob      ; fi
if [ "${SUDOERS}" = true ]; then sudoers      ; fi
# TODO: Force recreate users if they were deleted manually

log_info "Starting..."
sync_keys_output=$(sync_keys)

if (echo "${sync_keys_output}" | grep -Ewq '^download|delete'); then
    create_users_with_keys
    delete_users_without_keys
else
    # Delete manually created user accounts
    delete_users_without_keys
fi

log_info "Finished in ${SECONDS} sec."
