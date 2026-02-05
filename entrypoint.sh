#!/bin/bash

set -e

# -----------------------------------------------
# Cleanup function to remove SSH keys
# -----------------------------------------------
cleanup() {
    [[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: Cleaning up SSH keys..."
    rm -f ~/.ssh/rebase_key
    rm -f ~/.ssh/config
    rm -f ~/.ssh/known_hosts
    [[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: SSH keys removed"
}

# -----------------------------------------------
# Function to post comment to PR
# -----------------------------------------------
post_comment() {
    local status="$1"
    local before_history="$2"
    local after_history="$3"

    echo "Posting log as PR comment..."

    # Escape backticks
    local escaped_logs=$(sed 's/`/\\`/g' "$LOG_FILE")
    local escaped_before=$(printf "%s" "$before_history" | sed 's/`/\\`/g')
    local escaped_after=$(printf "%s" "$after_history" | sed 's/`/\\`/g')

    local body="### $status

---

#### 📌 Before Rebase (Top 20 Commits)
$( [[ -n "$escaped_before" ]] && echo "\`\`\`"$'\n'"$escaped_before"$'\n'"\`\`\`" || echo "_Not available_" )

---

#### 📌 After Rebase (Top 20 Commits)
$( [[ -n "$escaped_after" ]] && echo "\`\`\`"$'\n'"$escaped_after"$'\n'"\`\`\`" || echo "_Rebase failed — no updated history available_" )

---

#### 📝 Full Rebase Log
\`\`\`
$escaped_logs
\`\`\`
"

    local payload=$(jq -n --arg body "$body" '{body: $body}')

    curl -s -X POST \
        -H "${AUTH_HEADER}" \
        -H "${API_HEADER}" \
        -d "$payload" \
        "${URI}/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" >/dev/null

    echo "Logs posted."
}

# Trap EXIT to always cleanup SSH keys
trap cleanup EXIT

# -----------------------------------------------
# Prepare log file to capture all git output
# -----------------------------------------------
LOG_FILE=$(mktemp)
exec > >(tee -a "$LOG_FILE") 2>&1

# -----------------------------------------------
# Initialize debug mode early (before cleanup trap)
# -----------------------------------------------
COMMENT_BODY=$(jq -r ".comment.body" "$GITHUB_EVENT_PATH" 2>/dev/null || echo "")
if [[ "$COMMENT_BODY" == *"/rebase-debug"* ]]; then
    DEBUG_MODE=true
else
    DEBUG_MODE=false
fi

echo "Starting rebase process..."
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG MODE ENABLED - Verbose output will be shown"

# -----------------------------------------------
# Determine PR number
# -----------------------------------------------
if [ -z "$PR_NUMBER" ]; then
    PR_NUMBER=$(jq -r ".pull_request.number" "$GITHUB_EVENT_PATH")
    if [[ "$PR_NUMBER" == "null" ]]; then
        PR_NUMBER=$(jq -r ".issue.number" "$GITHUB_EVENT_PATH")
    fi
    if [[ "$PR_NUMBER" == "null" ]]; then
        echo "Failed to determine PR Number."
        exit 1
    fi
fi

echo "Collecting information about PR #$PR_NUMBER ..."

if [[ -z "$GITHUB_TOKEN" ]]; then
    echo "Set the GITHUB_TOKEN env variable."
    exit 1
fi

URI=https://api.github.com
API_HEADER="Accept: application/vnd.github.v3+json"
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

MAX_RETRIES=${MAX_RETRIES:-6}
RETRY_INTERVAL=${RETRY_INTERVAL:-10}

REBASEABLE=""
pr_resp=""

for ((i = 0 ; i < $MAX_RETRIES ; i++)); do
    pr_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
        "${URI}/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER")
    REBASEABLE=$(echo "$pr_resp" | jq -r .rebaseable)
    if [[ "$REBASEABLE" == "null" ]]; then
        echo "The PR is not ready to rebase, retry after $RETRY_INTERVAL seconds"
        sleep $RETRY_INTERVAL
        continue
    else
        break
    fi
done

if [[ "$REBASEABLE" != "true" ]] ; then
    echo "GitHub doesn't think that the PR is rebaseable!"
    POST_FAILURE=true
else
    POST_FAILURE=false
fi

BASE_REPO=$(echo "$pr_resp" | jq -r .base.repo.full_name)
BASE_BRANCH=$(echo "$pr_resp" | jq -r .base.ref)

COMMENT_USER_ID=$(jq -r ".comment.user.login" "$GITHUB_EVENT_PATH")
if [[ "$COMMENT_USER_ID" == "null" ]]; then
    COMMENT_USER_ID=$(jq -r ".pull_request.user.login" "$GITHUB_EVENT_PATH")
fi

user_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
    "${URI}/users/${COMMENT_USER_ID}")

USER_NAME=$(echo "$user_resp" | jq -r ".name")
if [[ "$USER_NAME" == "null" ]]; then
    USER_NAME=$COMMENT_USER_ID
fi
USER_NAME="${USER_NAME} (Rebase PR Action)"

USER_EMAIL=$(echo "$user_resp" | jq -r ".email")
if [[ "$USER_EMAIL" == "null" ]]; then
    USER_EMAIL="$COMMENT_USER_ID@users.noreply.github.com"
fi

if [[ -z "$BASE_BRANCH" ]]; then
    echo "Cannot get base branch information!"
    POST_FAILURE=true
fi

HEAD_REPO=$(echo "$pr_resp" | jq -r .head.repo.full_name)
HEAD_BRANCH=$(echo "$pr_resp" | jq -r .head.ref)

echo "PR #$PR_NUMBER information:"
echo "  Base repo:   $BASE_REPO"
echo "  Base branch: $BASE_BRANCH"
echo "  Head repo:   $HEAD_REPO"
echo "  Head branch: $HEAD_BRANCH"

# -----------------------------------------------
# Configure git
# -----------------------------------------------

[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: HEAD_REPO = $HEAD_REPO"
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: BASE_REPO = $BASE_REPO"

# Read credentials from action inputs (INPUT_* from action.yml) or environment
# Check INPUT_ variables first (from action inputs), then fall back to direct env vars
if [ -n "${INPUT_REBASE_USERNAME}" ]; then
    REBASE_USERNAME="${INPUT_REBASE_USERNAME}"
fi

if [ -n "${INPUT_REBASE_TOKEN}" ]; then
    REBASE_TOKEN="${INPUT_REBASE_TOKEN}"
fi

if [ -n "${INPUT_REBASE_KEY}" ]; then
    REBASE_KEY="${INPUT_REBASE_KEY}"
fi

[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: INPUT_REBASE_USERNAME = '${INPUT_REBASE_USERNAME}'"
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: REBASE_USERNAME (resolved) = '${REBASE_USERNAME}'"

# Check for required environment variables
if [ -z "${REBASE_USERNAME}" ]; then
    echo "ERROR: REBASE_USERNAME is required but not set"
    echo "ERROR: Set it via 'with:' in your workflow or as an environment variable"
    exit 1
fi

if [ -z "${REBASE_TOKEN}" ]; then
    echo "ERROR: REBASE_TOKEN is required but not set"
    echo "ERROR: Set it via 'with:' in your workflow or as an environment variable"
    exit 1
fi

if [ -z "${REBASE_KEY}" ]; then
    echo "ERROR: REBASE_KEY is required but not set"
    echo "ERROR: REBASE_KEY should contain the SSH private key for git operations"
    echo "ERROR: Set it via 'with:' in your workflow or as an environment variable"
    exit 1
fi

[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: REBASE_USERNAME = $REBASE_USERNAME"
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: REBASE_TOKEN is SET (length: ${#REBASE_TOKEN} chars)"
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: REBASE_KEY is SET (length: ${#REBASE_KEY} chars)"

# Trim whitespace from token
REBASE_TOKEN="$(echo -e "${REBASE_TOKEN}" | tr -d '[:space:]')"

# Setup SSH key for git operations
if [[ "$DEBUG_MODE" == "true" ]]; then
    echo "DEBUG: Setting up SSH key for git operations..."
    echo "DEBUG: HOME = $HOME"
    echo "DEBUG: Creating ~/.ssh directory at: $HOME/.ssh"
fi
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Write the SSH key to file (ensure proper line endings)
echo "$REBASE_KEY" > ~/.ssh/rebase_key
chmod 600 ~/.ssh/rebase_key

# Validate SSH key format
if ! ssh-keygen -y -f ~/.ssh/rebase_key > /dev/null 2>&1; then
    echo "ERROR: Invalid SSH key format in REBASE_KEY"
    echo "ERROR: Make sure you copied the entire private key including BEGIN and END lines"
    exit 1
fi
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: SSH key validation passed"

# Add GitHub's SSH host keys using ssh-keyscan
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: Scanning GitHub SSH host keys..."
ssh-keyscan -t rsa,ecdsa,ed25519 github.com 2>/dev/null > ~/.ssh/known_hosts
chmod 644 ~/.ssh/known_hosts
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: Known hosts file created with $(wc -l < ~/.ssh/known_hosts) entries"

# Configure SSH to use the key (use absolute paths, not ~)
cat > ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile $HOME/.ssh/rebase_key
  StrictHostKeyChecking yes
  UserKnownHostsFile $HOME/.ssh/known_hosts
EOF
chmod 600 ~/.ssh/config

if [[ "$DEBUG_MODE" == "true" ]]; then
    echo "DEBUG: SSH config file created at: $HOME/.ssh/config"
    echo "DEBUG: SSH config contents:"
    cat ~/.ssh/config
fi

# Set GIT_SSH_COMMAND to use our custom SSH options (bypasses SSH config file issues)
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/rebase_key -o UserKnownHostsFile=$HOME/.ssh/known_hosts -o StrictHostKeyChecking=yes"
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: GIT_SSH_COMMAND = $GIT_SSH_COMMAND"

[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: Setting up SSH authentication for fork repository..."

# See https://github.com/actions/checkout/issues/766 for motivation.
git config --global --add safe.directory /github/workspace

# Suppress detached HEAD advice message
git config --global advice.detachedHead false

[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: Setting origin remote: $GITHUB_REPOSITORY"
git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "$USER_EMAIL"
git config --global user.name "$USER_NAME"

# Use SSH for fork to bypass organization PAT restrictions
[[ "$DEBUG_MODE" == "true" ]] && echo "DEBUG: Adding fork remote (SSH): $HEAD_REPO"
git remote add fork git@github.com:$HEAD_REPO.git

# Test SSH connection (verbose mode only if /rebase-debug is used)
if [[ "$DEBUG_MODE" == "true" ]]; then
    echo "DEBUG: Running verbose SSH connection test..."
    ssh -vv -T git@github.com 2>&1 || true
fi

set +e

# -----------------------------------------------
# Fetch branches
# -----------------------------------------------
echo "Fetching base branch '$BASE_BRANCH' from origin..."
echo "+ git fetch origin $BASE_BRANCH"
git fetch origin $BASE_BRANCH

echo "Fetching head branch '$HEAD_BRANCH' from fork..."
echo "+ git fetch fork $HEAD_BRANCH"
if ! git fetch fork $HEAD_BRANCH; then
    echo "ERROR: Failed to fetch branch '$HEAD_BRANCH' from fork '$HEAD_REPO'"
    echo "ERROR: This usually means:"
    echo "  1. The SSH key doesn't have access to the fork repository"
    echo "  2. The repository doesn't exist or was renamed"
    echo "  3. The branch doesn't exist on the fork"
    echo "ERROR: Verify that REBASE_KEY has been added as a deploy key to $HEAD_REPO"
    POST_FAILURE=true
fi

# -----------------------------------------------
# Early exit if we already know we have failures
# -----------------------------------------------
if [[ "$POST_FAILURE" == "true" ]]; then
    echo "ERROR: Pre-rebase checks failed. Cannot proceed with rebase."
    echo "ERROR: Check the errors above for details."

    # Post failure comment before exiting
    post_comment "❌ Rebase Failed — Pre-rebase Checks Failed" "" ""
    exit 1
fi

echo "Checking out fork/$HEAD_BRANCH..."
echo "+ git checkout fork/$HEAD_BRANCH"
git checkout fork/$HEAD_BRANCH

# -----------------------------------------------
# Capture BEFORE rebase history
# -----------------------------------------------
echo "Collecting BEFORE rebase git history..."
echo "+ git log --graph --oneline --decorate -n 20"
BEFORE_HISTORY=$(git log --graph --oneline --decorate -n 20 || true)

# -----------------------------------------------
# Perform the rebase
# -----------------------------------------------
{
    if [[ $INPUT_AUTOSQUASH == 'true' ]]; then
        echo "Rebasing with autosquash..."
        echo "+ GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/$BASE_BRANCH"
        GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/$BASE_BRANCH
    else
        echo "Rebasing on $BASE_BRANCH..."
        echo "+ git rebase origin/$BASE_BRANCH"
        git rebase origin/$BASE_BRANCH
    fi

    REBASE_EXIT_CODE=$?
} || true

# -----------------------------------------------
# AFTER success: capture AFTER rebase history
# -----------------------------------------------
if [[ "$REBASE_EXIT_CODE" -eq 0 ]]; then
    echo "Collecting AFTER rebase git history..."
    echo "+ git log --graph --oneline --decorate -n 20"
    AFTER_HISTORY=$(git log --graph --oneline --decorate -n 20 || true)

    echo "Pushing rebased branch to fork via SSH..."
    echo "+ git push --force-with-lease fork HEAD:$HEAD_BRANCH"
    PUSH_OUTPUT=$(git push --force-with-lease fork HEAD:$HEAD_BRANCH 2>&1)
    PUSH_EXIT_CODE=$?

    echo "$PUSH_OUTPUT"

    if [[ "$PUSH_EXIT_CODE" -ne 0 ]]; then
        echo "ERROR: Failed to push rebased branch to $HEAD_REPO/$HEAD_BRANCH"
        echo "ERROR: This usually means:"
        echo "  1. The SSH key doesn't have write access to the repository"
        echo "  2. The branch is protected"
        echo "  3. Force push is disabled"
        echo "ERROR: Verify that REBASE_KEY has write permissions on $HEAD_REPO"
        REBASE_EXIT_CODE=1
    elif [[ "$PUSH_OUTPUT" == *"Everything up-to-date"* ]]; then
        echo "INFO: Remote branch is already up-to-date - no changes needed"
        echo "INFO: The PR branch was already rebased on the base branch"
    fi
else
    echo "WARN: Skipping push because rebase failed (exit code: $REBASE_EXIT_CODE)"
fi

set -e

# -----------------------------------------------
# POST COMMENT WITH FULL DETAILS
# -----------------------------------------------
if [[ "$REBASE_EXIT_CODE" -eq 0 ]]; then
    status="✅ Rebase Successful"
else
    status="❌ Rebase Failed — Conflict Detected"
fi

post_comment "$status" "$BEFORE_HISTORY" "$AFTER_HISTORY"

# -----------------------------------------------
# Exit based on rebase result
# -----------------------------------------------
if [[ "$REBASE_EXIT_CODE" -ne 0 ]]; then
    echo "Rebase failed. Logs posted."
    exit 1
fi

echo "Rebase succeeded. Logs posted."
exit 0