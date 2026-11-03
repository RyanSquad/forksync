# forksync

Automatically discovers **your** forked GitHub repositories and force-resets each fork’s **default branch** to match its upstream tip.

Runs daily via GitHub Actions (and on demand). Diverged history is overwritten — unique commits on the fork’s default branch are discarded.

## One-time setup

1. Create a Personal Access Token as the account that owns the forks:
   - **Classic:** `repo` scope
   - **Fine-grained:** repository access to all repos you fork (or “All repositories”), with **Contents: Read and write** and **Metadata: Read**
2. **Authorize the token for SAML SSO** (required for orgs that enforce SSO):
   - Open [GitHub → Settings → Developer settings → Personal access tokens](https://github.com/settings/tokens)
   - Find the token → **Configure SSO** (classic) or open the token and authorize each org
   - Click **Authorize** for every organization that owns upstreams (or your forks) protected by SSO
   - Complete the org SSO login if prompted
   - Re-authorize after regenerating the token; SSO grants do not carry over
3. In this repo, add a secret named `FORK_SYNC_TOKEN` with that token  
   (**Settings → Secrets and variables → Actions → New repository secret**).
4. Ensure Actions are enabled for this repository.

`GITHUB_TOKEN` is not enough — it cannot write to your other repositories. Without SSO authorization, API calls against SSO-protected orgs fail with 403.

## Run locally

Requires [GitHub CLI](https://cli.github.com/) (`gh`). On Windows, also need bash (Git for Windows).

```bash
# one-time auth (authorize SSO orgs when prompted)
gh auth login

# sync all of your forks (force-reset default branches)
bash scripts/sync-forks.sh
```

PowerShell:

```powershell
gh auth login
.\scripts\sync-forks.ps1
```

Optional: set `GH_TOKEN` or `FORK_SYNC_TOKEN` to a PAT instead of using `gh auth login`. For SSO orgs, authorize that token (Configure SSO) or run `gh auth refresh -h github.com`.

## Manual run (Actions)

**Actions → Sync forks → Run workflow**

## What it does

1. Lists repositories for the authenticated user where `fork == true`
2. For each fork with a parent upstream, reads the upstream default-branch commit SHA
3. If the fork default branch already points at that SHA, skips it
4. Otherwise force-updates the fork’s default-branch ref to the upstream SHA

Results appear in the workflow **Summary** tab.

## Warning

Force-reset **discards commits that exist only on the fork’s default branch**. Feature work should live on other branches or be pushed elsewhere before a sync runs.
