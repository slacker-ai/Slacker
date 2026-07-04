#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Slacker"
KEYCHAIN_SERVICE="com.slacker.Slacker"
APP_SUPPORT_DIR="${HOME}/Library/Application Support/${APP_NAME}"
DB_PATH="${APP_SUPPORT_DIR}/slacker.sqlite"

usage() {
  cat <<USAGE
Reset Slacker so the next launch starts onboarding again.

Usage:
  scripts/reset-onboarding.sh [--keep-llm-key] [--dry-run]

Options:
  --keep-llm-key   Keep the LLM API key in Keychain.
  --dry-run        Print what would be removed without changing anything.
USAGE
}

keep_llm_key=0
dry_run=0

for arg in "$@"; do
  case "$arg" in
    --keep-llm-key)
      keep_llm_key=1
      ;;
    --dry-run)
      dry_run=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: ${arg}" >&2
      usage >&2
      exit 2
      ;;
  esac
done

run() {
  if [[ "$dry_run" -eq 1 ]]; then
    printf '[dry-run]'
    for arg in "$@"; do
      printf ' %q' "$arg"
    done
    printf '\n'
  else
    "$@"
  fi
}

delete_keychain_account() {
  local account="$1"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "[dry-run] delete Keychain item service=${KEYCHAIN_SERVICE} account=${account}"
    return
  fi

  if security delete-generic-password -s "$KEYCHAIN_SERVICE" -a "$account" >/dev/null 2>&1; then
    echo "Deleted Keychain account: ${account}"
  else
    echo "Keychain account not found: ${account}"
  fi
}

workspace_ids=()
if [[ -f "$DB_PATH" ]] && command -v sqlite3 >/dev/null 2>&1; then
  while IFS= read -r workspace_id; do
    [[ -n "$workspace_id" ]] && workspace_ids+=("$workspace_id")
  done < <(sqlite3 "$DB_PATH" "SELECT id FROM workspace;" 2>/dev/null || true)
elif [[ -f "$DB_PATH" ]]; then
  echo "sqlite3 not found; per-workspace Slack tokens cannot be discovered from ${DB_PATH}." >&2
  echo "Install sqlite3 or delete remaining slack.user.token.<workspaceID> entries manually in Keychain Access." >&2
fi

echo "Resetting Slacker onboarding state."
echo "Database: ${DB_PATH}"
echo "Keychain service: ${KEYCHAIN_SERVICE}"

delete_keychain_account "slack.user.token"
for workspace_id in "${workspace_ids[@]}"; do
  delete_keychain_account "slack.user.token.${workspace_id}"
done

if [[ "$keep_llm_key" -eq 0 ]]; then
  delete_keychain_account "llm.api.key"
else
  echo "Keeping Keychain account: llm.api.key"
fi

if [[ -d "$APP_SUPPORT_DIR" ]]; then
  run rm -f \
    "${DB_PATH}" \
    "${DB_PATH}-shm" \
    "${DB_PATH}-wal"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "Would remove local database files."
  else
    echo "Removed local database files."
  fi
else
  echo "No Slacker Application Support directory found."
fi

echo "Done. Quit and relaunch Slacker to run onboarding from scratch."
