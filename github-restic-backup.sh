#!/usr/bin/env bash

###############################################################################
# GitHub Restic Backup Script
#
# This script performs a "smart" backup of all repositories for a given GitHub
# user. It:
#   - Fetches all repositories using the GitHub API and a Personal Access Token.
#   - Clones new repositories as mirrors and updates existing ones.
#   - Backs up the local mirrors directory using restic to an rclone remote.
#   - Prunes old restic snapshots according to a sensible retention policy.
#
# Security best practices are followed: secrets are never echoed, and all
# user-configurable settings are at the top.
###############################################################################

set -euo pipefail

##############################
# User-configurable settings #
##############################

# Load environment variables from .env if it exists
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
else
  echo "WARNING: .env file not found. Using defaults in script (if any)."
fi

##############################
# End of user settings       #
##############################

# Optionally, you can set fallback defaults here if desired, e.g.:
# : "${GITHUB_USER:=your-github-username}"
# : "${GITHUB_TOKEN_FILE:=$HOME/.github_pat}"
# : "${MIRRORS_DIR:=$HOME/github-mirrors}"
# : "${RESTIC_REPO:=rclone:myremote:restic-github-backup}"
# : "${RESTIC_PASSWORD_FILE:=$HOME/.restic_pass}"
# : "${RESTIC_KEEP_DAILY:=7}"
# : "${RESTIC_KEEP_WEEKLY:=4}"
# : "${RESTIC_KEEP_MONTHLY:=6}"
# : "${PARALLEL_JOBS:=4}"

# Check for required variables
required_vars=(GITHUB_USER GITHUB_TOKEN_FILE MIRRORS_DIR RESTIC_REPO RESTIC_PASSWORD_FILE RESTIC_KEEP_DAILY RESTIC_KEEP_WEEKLY RESTIC_KEEP_MONTHLY PARALLEL_JOBS)
for var in "${required_vars[@]}"; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required environment variable '$var' is not set. Please set it in your .env file."
    exit 1
  fi
done

# Required tools
REQUIRED_TOOLS=(curl jq git restic rclone)

#####################################
# Helper: Print error and exit      #
#####################################
die() {
    echo "ERROR: $*" >&2
    exit 1
}

#####################################
# Check for required tools          #
#####################################
echo "Checking for required tools..."
for tool in "${REQUIRED_TOOLS[@]}"; do
    command -v "$tool" >/dev/null 2>&1 || die "Required tool '$tool' not found in PATH."
done
echo "All required tools found."

#####################################
# Load secrets securely             #
#####################################
if [[ ! -r "$GITHUB_TOKEN_FILE" ]]; then
    die "GitHub token file not found or not readable: $GITHUB_TOKEN_FILE"
fi
GITHUB_TOKEN="$(<"$GITHUB_TOKEN_FILE")"

if [[ ! -r "$RESTIC_PASSWORD_FILE" ]]; then
    die "Restic password file not found or not readable: $RESTIC_PASSWORD_FILE"
fi

#####################################
# Fetch GitHub repositories         #
#####################################
echo "Fetching repositories for user '$GITHUB_USER' from GitHub..."

REPOS_JSON=$(curl -sSL -H "Authorization: token $GITHUB_TOKEN" \
    "https://api.github.com/users/$GITHUB_USER/repos?per_page=100&type=owner")

# Handle pagination if >100 repos
PAGE=2
while :; do
    PAGE_JSON=$(curl -sSL -H "Authorization: token $GITHUB_TOKEN" \
        "https://api.github.com/users/$GITHUB_USER/repos?per_page=100&type=owner&page=$PAGE")
    if [[ $(echo "$PAGE_JSON" | jq '. | length') -eq 0 ]]; then
        break
    fi
    REPOS_JSON=$(echo "$REPOS_JSON $PAGE_JSON" | jq -s 'add')
    ((PAGE++))
done

REPO_CLONE_URLS=($(echo "$REPOS_JSON" | jq -r '.[].clone_url'))

if [[ ${#REPO_CLONE_URLS[@]} -eq 0 ]]; then
    die "No repositories found for user '$GITHUB_USER'."
fi

echo "Found ${#REPO_CLONE_URLS[@]} repositories."

#####################################
# Clone or update repositories      #
#####################################
mkdir -p "$MIRRORS_DIR"

echo "Cloning new repositories and updating existing ones in '$MIRRORS_DIR'..."

clone_or_update_repo() {
    local url="$1"
    local name
    name="$(basename "$url" .git)"
    local dir="$MIRRORS_DIR/$name.git"
    if [[ -d "$dir" ]]; then
        echo "Updating $name..."
        git -C "$dir" remote update --prune
    else
        echo "Cloning $name..."
        git clone --mirror "$url" "$dir"
    fi
}

export -f clone_or_update_repo
export MIRRORS_DIR

printf "%s\n" "${REPO_CLONE_URLS[@]}" | xargs -n1 -P "$PARALLEL_JOBS" -I{} bash -c 'clone_or_update_repo "$@"' _ {}

echo "All repositories are up to date."

#####################################
# Restic backup                     #
#####################################
echo "Starting restic backup to '$RESTIC_REPO'..."

export RESTIC_PASSWORD_FILE

restic -r "$RESTIC_REPO" backup "$MIRRORS_DIR" \
    --tag github-backup \
    --verbose

echo "Restic backup completed."

#####################################
# Restic prune                      #
#####################################
echo "Pruning old restic snapshots (daily: $RESTIC_KEEP_DAILY, weekly: $RESTIC_KEEP_WEEKLY, monthly: $RESTIC_KEEP_MONTHLY)..."

restic -r "$RESTIC_REPO" forget \
    --keep-daily "$RESTIC_KEEP_DAILY" \
    --keep-weekly "$RESTIC_KEEP_WEEKLY" \
    --keep-monthly "$RESTIC_KEEP_MONTHLY" \
    --prune

echo "Restic prune completed."

#####################################
# Done                              #
#####################################
echo "GitHub repository backup and restic snapshot management complete."

exit 0
