#!/bin/bash
# Repository-local, checksum-pinned workflow validator. No global installation.
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.7.12
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64)
    target=darwin_arm64
    checksum=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
    ;;
  Linux-x86_64)
    target=linux_amd64
    checksum=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
    ;;
  *) printf 'Unsupported workflow-validator host.\n' >&2; exit 1 ;;
esac
mkdir -p .artifacts/release-automation
scratch=$(mktemp -d "$PWD/.artifacts/release-automation/actionlint.XXXXXX")
archive="$scratch/actionlint.tar.gz"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 120 \
  "https://github.com/rhysd/actionlint/releases/download/v${version}/actionlint_${version}_${target}.tar.gz" \
  --output "$archive"
test "$(shasum -a 256 "$archive" | cut -d ' ' -f 1)" = "$checksum"
tar -xzf "$archive" -C "$scratch" actionlint
# Python tests cover shell invocation contracts; shellcheck is not a dependency.
"$scratch/actionlint" -shellcheck= -pyflakes= .github/workflows/main-release.yml
