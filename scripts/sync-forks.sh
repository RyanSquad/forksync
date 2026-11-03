#!/usr/bin/env bash
# Discover personal forks and force-reset each default branch to match upstream.
# Local:  bash scripts/sync-forks.sh
# CI:     GH_TOKEN from FORK_SYNC_TOKEN secret
set -euo pipefail

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI is required (https://cli.github.com/)" >&2
  exit 1
fi

# Prefer explicit tokens; otherwise use credentials from `gh auth login`.
if [[ -z "${GH_TOKEN:-}" && -n "${FORK_SYNC_TOKEN:-}" ]]; then
  export GH_TOKEN="$FORK_SYNC_TOKEN"
fi

if [[ -z "${GH_TOKEN:-}" ]]; then
  if ! gh auth status >/dev/null 2>&1; then
    echo "error: not authenticated with GitHub." >&2
    echo "  Run:  gh auth login" >&2
    echo "  Or set GH_TOKEN / FORK_SYNC_TOKEN to a PAT (SSO-authorized if needed)." >&2
    exit 1
  fi
fi

# Returns 0 if stderr/stdout from a failed gh call looks like SAML SSO enforcement.
is_sso_error() {
  local text="${1:-}"
  grep -qiE 'saml|sso|organization sso|Resource protected by organization SAML' <<<"$text"
}

# Print actionable SSO guidance once when we first hit an SSO failure.
SSO_HINT_PRINTED=0
print_sso_hint() {
  if [[ "$SSO_HINT_PRINTED" -eq 1 ]]; then
    return
  fi
  SSO_HINT_PRINTED=1
  cat >&2 <<'EOF'
hint: this looks like a GitHub SAML SSO authorization issue.
  Token (Actions / GH_TOKEN):
    1. Open https://github.com/settings/tokens
    2. Configure SSO → Authorize each SSO-protected organization
  Local gh auth:
    gh auth status
    gh auth refresh -h github.com
    # then open the SSO authorize URL gh prints (or authorize in the browser)
EOF
}

fail_reason_from_err() {
  local fallback="$1"
  local err_text="$2"
  if is_sso_error "$err_text"; then
    print_sso_hint
    echo "failed (SSO not authorized)"
  else
    echo "$fallback"
  fi
}

# In Actions, write markdown to the job summary; locally print to the terminal.
SUMMARY_FILE="${GITHUB_STEP_SUMMARY:-/dev/stdout}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

RESULTS_TSV="$TMP_DIR/results.tsv"
: >"$RESULTS_TSV"

synced=0
skipped=0
failed=0

echo "Discovering forked repositories..."

# List all repos for the authenticated user; keep forks only.
# parent fields are not always present on list responses, so fetch details per fork.
LIST_ERR="$TMP_DIR/list.err"
if ! gh api user/repos --paginate \
  --jq '.[] | select(.fork == true) | .full_name' \
  >"$TMP_DIR/forks.txt" 2>"$LIST_ERR"; then
  echo "error: failed to list repositories" >&2
  cat "$LIST_ERR" >&2 || true
  if is_sso_error "$(cat "$LIST_ERR" 2>/dev/null || true)"; then
    print_sso_hint
  fi
  exit 1
fi

mapfile -t FORK_FULL_NAMES < <(sort -u "$TMP_DIR/forks.txt")

if [[ ${#FORK_FULL_NAMES[@]} -eq 0 || -z "${FORK_FULL_NAMES[0]:-}" ]]; then
  echo "No forked repositories found."
  {
    echo "## Fork sync results"
    echo
    echo "_No forked repositories found._"
  } >>"$SUMMARY_FILE"
  exit 0
fi

echo "Found ${#FORK_FULL_NAMES[@]} fork(s)."

for FORK in "${FORK_FULL_NAMES[@]}"; do
  [[ -z "$FORK" ]] && continue
  echo "----"
  echo "Processing $FORK"

  if ! LINE="$(gh api "repos/$FORK" --jq '[.parent.full_name // "", .default_branch // ""] | @tsv' 2>"$TMP_DIR/err")"; then
    err_text="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
    echo "error: failed to fetch details for $FORK" >&2
    echo "$err_text" >&2
    reason="$(fail_reason_from_err "failed (lookup)" "$err_text")"
    echo -e "${FORK}\t?\t${reason}" >>"$RESULTS_TSV"
    failed=$((failed + 1))
    continue
  fi

  PARENT="${LINE%%$'\t'*}"
  FORK_BRANCH="${LINE#*$'\t'}"

  if [[ -z "$PARENT" ]]; then
    echo "skip: $FORK has no parent"
    echo -e "${FORK}\t?\tskipped (no parent)" >>"$RESULTS_TSV"
    skipped=$((skipped + 1))
    continue
  fi

  if [[ -z "$FORK_BRANCH" ]]; then
    echo "error: $FORK has no default branch" >&2
    echo -e "${FORK}\t${PARENT}\tfailed (no default branch)" >>"$RESULTS_TSV"
    failed=$((failed + 1))
    continue
  fi

  if ! UPSTREAM_BRANCH="$(gh api "repos/$PARENT" --jq '.default_branch // empty' 2>"$TMP_DIR/err")"; then
    err_text="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
    echo "error: failed to fetch upstream $PARENT" >&2
    echo "$err_text" >&2
    reason="$(fail_reason_from_err "failed (upstream lookup)" "$err_text")"
    echo -e "${FORK}\t${PARENT}\t${reason}" >>"$RESULTS_TSV"
    failed=$((failed + 1))
    continue
  fi

  if [[ -z "$UPSTREAM_BRANCH" ]]; then
    echo "error: upstream $PARENT has no default branch" >&2
    echo -e "${FORK}\t${PARENT}\tfailed (upstream no default branch)" >>"$RESULTS_TSV"
    failed=$((failed + 1))
    continue
  fi

  if ! UPSTREAM_SHA="$(gh api "repos/$PARENT/git/ref/heads/$UPSTREAM_BRANCH" --jq '.object.sha' 2>"$TMP_DIR/err")"; then
    err_text="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
    echo "error: failed to resolve upstream SHA for $PARENT@$UPSTREAM_BRANCH" >&2
    echo "$err_text" >&2
    reason="$(fail_reason_from_err "failed (upstream SHA)" "$err_text")"
    echo -e "${FORK}\t${PARENT}\t${reason}" >>"$RESULTS_TSV"
    failed=$((failed + 1))
    continue
  fi

  FORK_SHA=""
  if FORK_SHA="$(gh api "repos/$FORK/git/ref/heads/$FORK_BRANCH" --jq '.object.sha' 2>"$TMP_DIR/err")"; then
    if [[ "$FORK_SHA" == "$UPSTREAM_SHA" ]]; then
      echo "already up to date: $FORK ($FORK_BRANCH) == $PARENT ($UPSTREAM_BRANCH) @ ${UPSTREAM_SHA:0:7}"
      echo -e "${FORK}\t${PARENT}\tskipped (up to date)" >>"$RESULTS_TSV"
      skipped=$((skipped + 1))
      continue
    fi
  else
    err_text="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
    if is_sso_error "$err_text"; then
      echo "error: SSO blocked reading tip for $FORK@$FORK_BRANCH" >&2
      echo "$err_text" >&2
      reason="$(fail_reason_from_err "failed (lookup)" "$err_text")"
      echo -e "${FORK}\t${PARENT}\t${reason}" >>"$RESULTS_TSV"
      failed=$((failed + 1))
      continue
    fi
    # Missing fork branch is OK; force-update will create/update the ref if possible.
    echo "note: could not read current tip for $FORK@$FORK_BRANCH; will force-update"
  fi

  echo "force-reset $FORK@$FORK_BRANCH -> $PARENT@$UPSTREAM_BRANCH (${UPSTREAM_SHA:0:7})"
  if gh api -X PATCH "repos/$FORK/git/refs/heads/$FORK_BRANCH" \
    -f sha="$UPSTREAM_SHA" \
    -F force=true >/dev/null 2>"$TMP_DIR/err"; then
    echo "synced: $FORK"
    echo -e "${FORK}\t${PARENT}\tsynced" >>"$RESULTS_TSV"
    synced=$((synced + 1))
  else
    err_text="$(cat "$TMP_DIR/err" 2>/dev/null || true)"
    echo "error: force-update failed for $FORK" >&2
    echo "$err_text" >&2
    reason="$(fail_reason_from_err "failed (force-update)" "$err_text")"
    echo -e "${FORK}\t${PARENT}\t${reason}" >>"$RESULTS_TSV"
    failed=$((failed + 1))
  fi
done

{
  echo "## Fork sync results"
  echo
  echo "| Fork | Upstream | Result |"
  echo "| --- | --- | --- |"
  while IFS=$'\t' read -r fork upstream result; do
    echo "| \`$fork\` | \`$upstream\` | $result |"
  done <"$RESULTS_TSV"
  echo
  echo "**Totals:** synced=$synced, skipped=$skipped, failed=$failed"
  if [[ "$SSO_HINT_PRINTED" -eq 1 ]]; then
    echo
    echo "> Some failures look like **SAML SSO** authorization gaps. Authorize the token (Configure SSO) or run \`gh auth refresh -h github.com\`, then re-run."
  fi
} >>"$SUMMARY_FILE"

echo "----"
echo "Done. synced=$synced skipped=$skipped failed=$failed"

if [[ "$failed" -gt 0 ]]; then
  exit 1
fi
