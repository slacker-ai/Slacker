#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: scripts/setup-sparkle-signing.sh /secure/path/slacker-sparkle-private-key" >&2
  exit 64
fi

REPOSITORY_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PRIVATE_KEY_PATH="$1"
SPARKLE_ACCOUNT="com.slacker.Slacker"
SOURCE_PACKAGES_PATH="$REPOSITORY_ROOT/build/SourcePackages"
GENERATE_KEYS="$SOURCE_PACKAGES_PATH/artifacts/sparkle/Sparkle/bin/generate_keys"

if [[ -e "$PRIVATE_KEY_PATH" ]]; then
  echo "refusing to overwrite existing private key file: $PRIVATE_KEY_PATH" >&2
  exit 73
fi

if [[ ! -x "$GENERATE_KEYS" ]]; then
  command -v xcodegen >/dev/null || {
    echo "xcodegen is required (brew install xcodegen)" >&2
    exit 69
  }
  cd "$REPOSITORY_ROOT"
  xcodegen generate
  xcodebuild \
    -project Slacker.xcodeproj \
    -scheme Slacker \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    -resolvePackageDependencies
fi

[[ -x "$GENERATE_KEYS" ]] || {
  echo "Sparkle generate_keys tool was not found after package resolution" >&2
  exit 70
}

# Sparkle stores the canonical private seed in the login Keychain. The exported file is
# only for securely transferring that seed into GitHub Actions and an offline backup.
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT"
PUBLIC_KEY="$("$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -p)"
umask 077
mkdir -p "$(dirname "$PRIVATE_KEY_PATH")"
"$GENERATE_KEYS" --account "$SPARKLE_ACCOUNT" -x "$PRIVATE_KEY_PATH"

echo
echo "Sparkle signing key is ready. Configure this repository with:"
echo "  gh variable set SPARKLE_PUBLIC_ED_KEY --body '$PUBLIC_KEY'"
echo "  gh secret set SPARKLE_EDDSA_PRIVATE_KEY < '$PRIVATE_KEY_PATH'"
echo
echo "Keep $PRIVATE_KEY_PATH in a secure offline backup. Never commit it."
