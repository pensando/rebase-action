#!/bin/bash

set -e

# -----------------------------------------------
# Cleanup function to remove SSH keys
# -----------------------------------------------
cleanup() {
    echo "DEBUG: Cleaning up SSH keys..."
    rm -f ~/.ssh/rebase_key
    rm -f ~/.ssh/config
    echo "DEBUG: SSH keys removed"
}

# Trap EXIT to always cleanup SSH keys
trap cleanup EXIT

# -----------------------------------------------
# Prepare log file to capture all git output
# -----------------------------------------------
LOG_FILE=$(mktemp)
exec > >(tee -a "$LOG_FILE") 2>&1

echo "Starting rebase process..."

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

echo "Base branch for PR #$PR_NUMBER is $BASE_BRANCH"

# -----------------------------------------------
# Configure git
# -----------------------------------------------

echo "DEBUG: HEAD_REPO = $HEAD_REPO"
echo "DEBUG: BASE_REPO = $BASE_REPO"

# Check for required environment variables
if [ -z "${REBASE_USERNAME}" ]; then
    echo "ERROR: REBASE_USERNAME is required but not set"
    exit 1
fi

if [ -z "${REBASE_TOKEN}" ]; then
    echo "ERROR: REBASE_TOKEN is required but not set"
    exit 1
fi

if [ -z "${REBASE_KEY}" ]; then
    echo "ERROR: REBASE_KEY is required but not set"
    echo "ERROR: REBASE_KEY should contain the SSH private key for git operations"
    exit 1
fi

echo "DEBUG: REBASE_USERNAME = $REBASE_USERNAME"
echo "DEBUG: REBASE_TOKEN is SET (length: ${#REBASE_TOKEN} chars)"
echo "DEBUG: REBASE_KEY is SET (length: ${#REBASE_KEY} chars)"

# Trim whitespace from token
REBASE_TOKEN="$(echo -e "${REBASE_TOKEN}" | tr -d '[:space:]')"

# Setup SSH key for git operations
echo "DEBUG: Setting up SSH key for git operations..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Write the SSH key to file
echo "$REBASE_KEY" > ~/.ssh/rebase_key
chmod 600 ~/.ssh/rebase_key

# Configure SSH to use the key
cat > ~/.ssh/config <<EOF
Host github.com
  HostName github.com
  User git
  IdentityFile ~/.ssh/rebase_key
  StrictHostKeyChecking no
  UserKnownHostsFile=/dev/null
EOF
chmod 600 ~/.ssh/config

echo "DEBUG: SSH key configured"

# See https://github.com/actions/checkout/issues/766 for motivation.
git config --global --add safe.directory /github/workspace

echo "DEBUG: Setting origin remote: $GITHUB_REPOSITORY"
git remote set-url origin https://x-access-token:$GITHUB_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "$USER_EMAIL"
git config --global user.name "$USER_NAME"

# Use SSH for fork to bypass organization PAT restrictions
echo "DEBUG: Adding fork remote (SSH): $HEAD_REPO"
git remote add fork git@github.com:$HEAD_REPO.git

# Test SSH connection
echo "DEBUG: Testing SSH connection to GitHub..."
ssh -T git@github.com 2>&1 | head -n 3 || echo "DEBUG: SSH test completed"

set +e

# -----------------------------------------------
# Fetch branches
# -----------------------------------------------
echo "DEBUG: Fetching base branch '$BASE_BRANCH' from origin..."
git fetch origin $BASE_BRANCH

echo "DEBUG: Fetching head branch '$HEAD_BRANCH' from fork..."
if ! git fetch fork $HEAD_BRANCH; then
    echo "ERROR: Failed to fetch branch '$HEAD_BRANCH' from fork '$HEAD_REPO'"
    echo "ERROR: This usually means:"
    echo "  1. The SSH key doesn't have access to the fork repository"
    echo "  2. The repository doesn't exist or was renamed"
    echo "  3. The branch doesn't exist on the fork"
    echo "ERROR: Verify that REBASE_KEY has been added as a deploy key to $HEAD_REPO"
    POST_FAILURE=true
fi

echo "DEBUG: Checking out fork/$HEAD_BRANCH..."
echo "DEBUG: git checkout fork/$HEAD_BRANCH"
git checkout fork/$HEAD_BRANCH

# -----------------------------------------------
# Early exit if we already know we have failures
# -----------------------------------------------
if [[ "$POST_FAILURE" == "true" ]]; then
    echo "ERROR: Pre-rebase checks failed. Cannot proceed with rebase."
    echo "ERROR: Check the errors above for details."
    exit 1
fi

# -----------------------------------------------
# Capture BEFORE rebase history
# -----------------------------------------------
echo "Collecting BEFORE rebase git history..."
BEFORE_HISTORY=$(git log --graph --oneline --decorate -n 20 || true)

# -----------------------------------------------
# Perform the rebase
# -----------------------------------------------
{
    if [[ $INPUT_AUTOSQUASH == 'true' ]]; then
        GIT_SEQUENCE_EDITOR=: git rebase -i --autosquash origin/$BASE_BRANCH
    else
        git rebase origin/$BASE_BRANCH
    fi

    REBASE_EXIT_CODE=$?
} || true

# -----------------------------------------------
# AFTER success: capture AFTER rebase history
# -----------------------------------------------
if [[ "$REBASE_EXIT_CODE" -eq 0 ]]; then
    echo "Collecting AFTER rebase git history..."
    AFTER_HISTORY=$(git log --graph --oneline --decorate -n 20 || true)

    echo "DEBUG: Pushing rebased branch to fork via SSH..."
    echo "DEBUG: Command: git push --force-with-lease fork HEAD:$HEAD_BRANCH"
    if ! git push --force-with-lease fork HEAD:$HEAD_BRANCH; then
        echo "ERROR: Failed to push rebased branch to $HEAD_REPO/$HEAD_BRANCH"
        echo "ERROR: This usually means:"
        echo "  1. The SSH key doesn't have write access to the repository"
        echo "  2. The branch is protected"
        echo "  3. Force push is disabled"
        echo "ERROR: Verify that REBASE_KEY has write permissions on $HEAD_REPO"
        REBASE_EXIT_CODE=1
    fi
else
    echo "WARN: Skipping push because rebase failed (exit code: $REBASE_EXIT_CODE)"
fi

set -e

# -----------------------------------------------
# POST COMMENT WITH FULL DETAILS
# -----------------------------------------------
echo "Posting log as PR comment..."

# Escape backticks
escaped_logs=$(sed 's/`/\\`/g' "$LOG_FILE")
escaped_before=$(printf "%s" "$BEFORE_HISTORY" | sed 's/`/\\`/g')
escaped_after=$(printf "%s" "$AFTER_HISTORY" | sed 's/`/\\`/g')

if [[ "$REBASE_EXIT_CODE" -eq 0 ]]; then
    status="✅ Rebase Successful"
else
    status="❌ Rebase Failed — Conflict Detected"
fi

body="### $status

---

#### 📌 Before Rebase (Top 20 Commits)
\`\`\`
$escaped_before
\`\`\`

---

#### 📌 After Rebase (Top 20 Commits)
$( [[ "$REBASE_EXIT_CODE" -eq 0 ]] && echo "\`\`\`"$'\n'"$escaped_after"$'\n'"\`\`\`" || echo "_Rebase failed — no updated history available_" )

---

#### 📝 Full Rebase Log
\`\`\`
$escaped_logs
\`\`\`
"

payload=$(jq -n --arg body "$body" '{body: $body}')

curl -s -X POST \
    -H "${AUTH_HEADER}" \
    -H "${API_HEADER}" \
    -d "$payload" \
    "${URI}/repos/$GITHUB_REPOSITORY/issues/$PR_NUMBER/comments" >/dev/null

echo "Logs posted."

# -----------------------------------------------
# Exit based on rebase result
# -----------------------------------------------
if [[ "$REBASE_EXIT_CODE" -ne 0 ]]; then
    echo "Rebase failed. Logs posted."
    exit 1
fi

echo "Rebase succeeded. Logs posted."
