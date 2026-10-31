#!/usr/bin/env bash
# Build the full DSH Go app with the Codex entry in a separate test package.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ ! -f "$repo_root/runtime/out/arm64-v8a/assets/runtime/manifest.json" ]]; then
  echo 'Missing arm64 DSH runtime. Prepare runtime/out first; see runtime/build-runtime.sh.' >&2
  exit 1
fi
# Keep concurrent Gradle work bounded on the shared 16 GB server.
GRADLE_OPTS="${GRADLE_OPTS:-} -Dorg.gradle.workers.max=2 -Dorg.gradle.parallel=false" \
ORG_GRADLE_PROJECT_codexPreview=true DSH_BETA_TOKEN_FILE= \
  "$repo_root/tooling/build-apk.sh" --release -f arm64 --keep-daemon -- "$@"
mkdir -p "$repo_root/dist"
cp "$repo_root/app/build/app/outputs/flutter-apk/app-arm64-release.apk" \
  "$repo_root/dist/dsh-go-codex-preview-arm64.apk"
cd "$repo_root/dist"
sha256sum dsh-go-codex-preview-arm64.apk > dsh-go-codex-preview-arm64.apk.sha256
printf 'APK: %s/dist/dsh-go-codex-preview-arm64.apk\n' "$repo_root"
