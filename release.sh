#!/usr/bin/env bash

set -e # Exit on error
set -u # Treat unset variable as error
set -o pipefail

# ------------------------------------------------------------------------------
# Usage
# ------------------------------------------------------------------------------
usage() {
    cat << EOF
Usage: $0 -h|--help
Usage: $0

Tool which adds tag with version number and uploads versioned archive to S3.

Options:

  -i, --increment [major|minor|patch]  Increment number of major, minor or patch version:
                                       - major: increment major version number by 1 (e.g. 0.1.2 to 2.0.0)
                                       - minor: increment minor version number by 1 (e.g. 0.1.2 to 0.2.0)
                                       - patch: increment patch version number by 1 (e.g. 0.1.2 to 0.1.3), default value.
  -s, --suffix [suffix]                Append this suffix to version number and archive name.
  -p, --s3-path [path]                 Full path including bucket name to which the archive will be uploaded (e.g. mybucket/releases/).
  -r, --region [region]                Owerride default eu-centra-1 region for AWS CLI.
  -t, --tag                            Tag git HEAD commit with new version number and push to remote repository.
  -u, --upload                         Create and upload archive to S3.
  -d, --debug                          Enable bash debugging.
  --dry-run                            Dry run.

Examples:

  Take commited files from git HEAD, tag HEAD with incremented patch version number, upload to S3:

    $0 --increment patch --tag --upload

  Take commited files from git HEAD, upload archive with incremented patch version number in name and appended suffix 'some-feature' to S3:

    $0 --increment patch --suffix some-feature --upload

EOF
}

# ------------------------------------------------------------------------------
# Parse options and their arguments
# ------------------------------------------------------------------------------
# If no options, print usage and exit
if [ $# -eq 0 ] ; then
    usage
    exit 2
fi

while [ $# -ne 0 ]; do
    arg="$1"
    shift
    case "$arg" in
        -h|--help)      usage; exit 0
                        ;;
        -i|--increment) increment=$1; shift
                        ;;
        -s|--suffix)    suffix=$1; shift
                        ;;
        -p|--s3-path)   s3_path=$1; shift
                        ;;
        -r|--region)    region=$1; shift
                        ;;
        -t|--tag)       tag=true
                        ;;
        -u|--upload)    upload=true
                        ;;
        -d|--debug)     set -o xtrace
                        ;;
        *)              usage; exit 1
                        ;;
    esac
done

# Set default values in case they are not set via options
increment=${increment:-}
suffix=${suffix:-}
s3_path=${s3_path:-}
region=${region:-$(aws configure get default.region)}

# ------------------------------------------------------------------------------
# Prepare next version number
# ------------------------------------------------------------------------------
# Get latest version number from git tags (tag/release)
version=$(git tag | sort -V | tail -n 1)

# Split version string into an array (replace dots and dashes with spaces)
version_parts=(${version//[.-]/ })

# Get major, minor and patch version numbers from array
# See Semantic Versioning - https://semver.org/
major_version=${version_parts[0]:-0}
minor_version=${version_parts[1]:-}
patch_version=${version_parts[2]:-}

case "$increment" in
    major)
        # Increment major version number and reset minor and patch versions
        major_version=$((major_version+1))
        minor_version=${minor_version:+0}
        patch_version=${patch_version:+0}
        ;;
    minor)
        # Increment minor version number and reset patch version
        minor_version=$((minor_version+1))
        patch_version=${patch_version:+0}
        ;;
    patch)
        # Increment patch version number
        patch_version=$((patch_version+1))
        minor_version=${minor_version:-0}
        ;;
    '')
        # Do not increment version number
        ;;
    *)
        echo "$0: incorrect argument, «${increment}», «--increment»"
        echo "List of correct arguments: [major|minor|patch]"
        exit 1
        ;;
esac

# Make next version number
next_version="${major_version}"
next_version="${next_version}${minor_version:+.$minor_version}"
next_version="${next_version}${patch_version:+.$patch_version}"
# Append suffix to the next version number
next_version="${next_version}${suffix:+-$suffix}"

echo "Current version: ${version:-none}"
echo "Next version: ${next_version}"

# ------------------------------------------------------------------------------
# Tag with next version and push it to remote repository only if no tag already
# ------------------------------------------------------------------------------
if [ "${tag:-false}" = true ]; then
    # Get current commit id and check if it's already tagged
    commit_id=$(git rev-parse HEAD)
    existing_tag=$(git tag --points-at $commit_id)

    if [ -z "${existing_tag}" ]; then
        echo "Adding tag with next version..."
        git tag $next_version
        git push origin $next_version
        echo "Tagged with ${next_version} version and pushed to remote repository."
    else
        echo "Commit ${commit_id} is already tagged with ${existing_tag} version. Aborting."
        exit 1
    fi
fi

# ------------------------------------------------------------------------------
# Create archive and upload to S3
# ------------------------------------------------------------------------------
if [ "${upload:-false}" = true ]; then
    tmp_dir=$(basename "$0")
    tmp_dir=tmp-${tmp_dir%.*}
    mkdir -p $tmp_dir

    # Create archive from git HEAD
    echo "Creating archive containing files from git HEAD..."
    git archive HEAD --prefix="${next_version}"/ \
                     --output="./${tmp_dir}/${next_version}.tar.gz"

    # Create archive from working tree
    #echo "Creating archive containing files from current directory..."
    #tar --exclude .git --exclude $tmp_dir \
    #    -caf ./${tmp_dir}/${next_version}.tar.gz . \
    #    --transform "s/^\./${next_version}/"

    # Upload archive to S3 bucket
    echo "Uploading ${next_version}.tar.gz to S3 (${region})"
    aws s3 cp ./${tmp_dir}/${next_version}.tar.gz \
              s3://${s3_path}                     \
              --region ${region}                  \
              --acl bucket-owner-full-control     \
              --no-progress
    rm -rf $tmp_dir
    echo 'Done.'
fi
