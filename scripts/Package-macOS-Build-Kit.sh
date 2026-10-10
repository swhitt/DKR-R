#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="${DKR_RELEASE_VERSION:-$(tr -d '\r\n' <"${project_root}/VERSION")}"
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo 'Invalid release version.' >&2
  exit 1
}
kit_name="DKR-R-${version}-macOS-Build-Kit"
stage_root="${DKR_MAC_KIT_STAGE_ROOT:-${project_root}/build/${version}-macos-kit-staging}"
stage="${stage_root}/${kit_name}"
output="${project_root}/dist/${kit_name}.tar.gz"

[[ ! -e "${stage}" ]] || {
  echo "macOS build-kit staging already exists: ${stage}" >&2
  exit 1
}
[[ ! -e "${output}" ]] || {
  echo "macOS build-kit archive already exists: ${output}" >&2
  exit 1
}

mkdir -p "${stage}"
# Copy the current tracked source, including the lockfile. Local ROMs,
# generated payloads and dependency checkouts are not part of the kit;
# Build-macOS.sh fetches and verifies dependencies on the recipient's Mac.
git -C "${project_root}" ls-files -z |
  rsync -a --from0 --files-from=- "${project_root}/" "${stage}/"
install -m 0755 "${project_root}/Build-macOS.sh" "${stage}/Build-macOS.sh"
install -m 0755 "${project_root}/Run-macOS.sh" "${stage}/Run-macOS.sh"
install -m 0644 "${project_root}/packaging/MACOS-BUILD-README.md" \
  "${stage}/README.md"

python3 - "${stage}" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
denied = {".z64", ".v64", ".n64", ".eep", ".mpk", ".o2r", ".otr"}
headers = {b"\x80\x37\x12\x40", b"\x37\x80\x40\x12", b"\x40\x12\x37\x80"}
inspected = 0
for path in root.rglob("*"):
    if not path.is_file():
        continue
    inspected += 1
    if path.suffix.lower() in denied:
        raise SystemExit(f"macOS build kit contains prohibited game data: {path}")
    with path.open("rb") as stream:
        if stream.read(4) in headers:
            raise SystemExit(f"macOS build kit contains an N64 ROM header: {path}")
print(f"macOS build-kit scan passed: {inspected} files inspected")
PY

mkdir -p "${project_root}/dist"
tar -C "${stage_root}" -czf "${output}" "${kit_name}"
printf 'Created %s\n' "${output}"
shasum -a 256 "${output}"
