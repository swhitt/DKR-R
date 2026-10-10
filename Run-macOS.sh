#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app=""
build_dir="${DKR_MAC_BUILD_DIR:-${project_root}/build/dkr-runtime-macos}"
[[ -d "${build_dir}/bin" ]] || {
  echo 'DKR-R.app is missing. Run ./Build-macOS.sh --help for build instructions.' >&2
  exit 1
}
while IFS= read -r candidate; do
  app="${candidate}"
  break
done < <(find "${build_dir}/bin" -type d -name 'DKR-R.app' -print)
[[ -n "${app}" && -d "${app}" ]] || {
  echo 'DKR-R.app is missing. Run ./Build-macOS.sh first.' >&2
  exit 1
}
open "${app}"
