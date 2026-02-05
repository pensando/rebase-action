# GitHub action to automatically rebase PRs

[![Build Status](https://api.cirrus-ci.com/github/cirrus-actions/rebase.svg)](https://cirrus-ci.com/github/cirrus-actions/rebase) [![](https://images.microbadger.com/badges/version/cirrusactions/rebase.svg)](https://microbadger.com/images/cirrusactions/rebase) [![](https://images.microbadger.com/badges/image/cirrusactions/rebase.svg)](https://microbadger.com/images/cirrusactions/rebase)

After installation simply comment `/rebase` to trigger the action:

![rebase-action](https://user-images.githubusercontent.com/989066/51547853-14a57b00-1e35-11e9-841d-33114f0f0bd5.gif)

# Installation

To configure the action simply add the following lines to your `.github/workflows/rebase.yml` workflow file:

```yaml
name: Automatic Rebase
on:
  issue_comment:
    types: [created]
jobs:
  rebase:
    name: Rebase
    runs-on: ubuntu-latest
    if: >-
      github.event.issue.pull_request != '' &&
      (
        contains(github.event.comment.body, '/rebase') ||
        contains(github.event.comment.body, '/autosquash') ||
        contains(github.event.comment.body, '/rebase-debug')
      )
    steps:
      - name: Checkout the latest code
        uses: actions/checkout@v3
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          fetch-depth: 0 # otherwise, you will fail to push refs to dest repo
      - name: Automatic Rebase
        uses: cirrus-actions/rebase@1.8
        with:
          autosquash: ${{ contains(github.event.comment.body, '/autosquash') || contains(github.event.comment.body, '/rebase-autosquash') }}
          rebase_username: ${{ secrets.REBASE_USERNAME }}
          rebase_token: ${{ secrets.REBASE_TOKEN }}
          rebase_key: ${{ secrets.REBASE_KEY }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Required Secrets

This action requires three secrets to be configured in your repository:

### REBASE_USERNAME
The GitHub username that owns the fork repository.

**Setup:**
1. Go to base repository Settings → Secrets and variables → Actions
2. New repository secret
3. Name: `REBASE_USERNAME`
4. Value: Your GitHub username (e.g., `leslie-qiwa`)

### REBASE_TOKEN
A [Personal Access Token](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/creating-a-personal-access-token) with `repo` scope for API access.

**Setup:**
1. Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Click "Generate new token (classic)"
3. Select the `repo` scope
4. Generate and copy the token
5. Add it to your repository secrets as `REBASE_TOKEN`

### REBASE_KEY
An SSH private key (deploy key) for git operations on fork repositories. This bypasses organization PAT restrictions.

**Setup:**
1. Generate an SSH key pair:
   ```bash
   ssh-keygen -t ed25519 -C "rebase-action" -f rebase_key -N ""
   ```

2. Add the **public key** (`rebase_key.pub`) as a deploy key to the fork repository:
   - Go to fork repository Settings → Deploy keys → Add deploy key
   - Title: "Rebase Action"
   - Key: paste contents of `rebase_key.pub`
   - ✅ **Allow write access** (required for pushing)

3. Add the **private key** (`rebase_key`) to repository secrets as `REBASE_KEY`:
   - Go to base repository Settings → Secrets and variables → Actions
   - New repository secret
   - Name: `REBASE_KEY`
   - Value: paste entire contents of `rebase_key` file (including `-----BEGIN` and `-----END` lines)

### REBASE_USERNAME
## Why SSH Keys?

This action uses SSH keys for git operations (fetch/push) instead of Personal Access Tokens because:
- Many organizations restrict PAT usage in GitHub Actions for security
- SSH deploy keys work reliably across organization boundaries
- PATs work fine for API calls but may fail for git operations from Actions runners

## Complete Example Workflow

```yaml
name: Automatic Rebase
on:
  issue_comment:
    types: [created]
jobs:
  rebase:
    name: Rebase
    runs-on: ubuntu-latest
    if: >-
      github.event.issue.pull_request != '' &&
      (
        contains(github.event.comment.body, '/rebase') ||
        contains(github.event.comment.body, '/autosquash') ||
        contains(github.event.comment.body, '/rebase-debug')
      )
    steps:
      - name: Checkout the latest code
        uses: actions/checkout@v3
        with:
          token: ${{ secrets.GITHUB_TOKEN }}
          fetch-depth: 0
      - name: Automatic Rebase
        uses: cirrus-actions/rebase@1.8
        with:
          autosquash: ${{ contains(github.event.comment.body, '/autosquash') }}
          rebase_username: ${{ secrets.REBASE_USERNAME }}
          rebase_token: ${{ secrets.REBASE_TOKEN }}
          rebase_key: ${{ secrets.REBASE_KEY }}
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```


## Restricting who can call the action

It's possible to use `author_association` field of a comment to restrict who can call the action and skip the rebase for others. Simply add the following expression to the `if` statement in your workflow file: `github.event.comment.author_association == 'MEMBER'`. See [documentation](https://developer.github.com/v4/enum/commentauthorassociation/) for a list of all available values of `author_association`.

GitHub can also optionally dismiss an existing review automatically after rebase, so you'll need to re-approve again which will trigger the test workflow.
Set it up in your repository *Settings* > *Branches* > *Branch protection rules* > *Require pull request reviews before merging* > *Dismiss stale pull request approvals when new commits are pushed*.
