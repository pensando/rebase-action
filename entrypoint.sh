#!/bin/bash

set -e

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

USER_LOGIN=$(jq -r ".comment.user.login" "$GITHUB_EVENT_PATH")
if [[ "$USER_LOGIN" == "null" ]]; then
    USER_LOGIN=$(jq -r ".pull_request.user.login" "$GITHUB_EVENT_PATH")
fi

user_resp=$(curl -X GET -s -H "${AUTH_HEADER}" -H "${API_HEADER}" \
    "${URI}/users/${USER_LOGIN}")

USER_NAME=$(echo "$user_resp" | jq -r ".name")
if [[ "$USER_NAME" == "null" ]]; then
    USER_NAME=$USER_LOGIN
fi
USER_NAME="${USER_NAME} (Rebase PR Action)"

USER_EMAIL=$(echo "$user_resp" | jq -r ".email")
if [[ "$USER_EMAIL" == "null" ]]; then
    USER_EMAIL="$USER_LOGIN@users.noreply.github.com"
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

USER_TOKEN="${USER_LOGIN//-/_}_TOKEN"
UNTRIMMED_COMMITTER_TOKEN=${!USER_TOKEN:-$GITHUB_TOKEN}
COMMITTER_TOKEN="$(echo -e "${UNTRIMMED_COMMITTER_TOKEN}" | tr -d '[:space:]')"

# See https://github.com/actions/checkout/issues/766 for motivation.
git config --global --add safe.directory /github/workspace

git remote set-url origin https://x-access-token:$COMMITTER_TOKEN@github.com/$GITHUB_REPOSITORY.git
git config --global user.email "$USER_EMAIL"
git config --global user.name "$USER_NAME"

git remote add fork https://x-access-token:$COMMITTER_TOKEN@github.com/$HEAD_REPO.git

set +e

# -----------------------------------------------
# Fetch branches
# -----------------------------------------------
git fetch origin $BASE_BRANCH
git fetch fork $HEAD_BRANCH

git checkout -b fork/$HEAD_BRANCH fork/$HEAD_BRANCH

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

    git push --force-with-lease fork fork/$HEAD_BRANCH:$HEAD_BRANCH
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
