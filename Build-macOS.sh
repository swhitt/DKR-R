#!/usr/bin/env bash
# One-command macOS build: prepares dependencies and both recompiled
# payloads from your ROMs, then builds, tests and packages DKR-R.app.
#   ./Build-macOS.sh --rom-v77 <US 1.0 ROM> --rom-v80 <US Rev A ROM>
# Prebuilt payloads can be supplied instead with DKR_MAC_GENERATED_SOURCE and
# DKR_MAC_V80_GENERATED_SOURCE. Prepare options (--skip-deps, --force,
# --jobs) are passed through.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
prepare_args=()
jobs="${CMAKE_BUILD_PARALLEL_LEVEL:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --rom-v77 | --rom-v80 | --jobs)
      [[ $# -ge 2 && "$2" != --* && -n "$2" ]] || {
        echo "$1 requires a value." >&2
        exit 1
      }
      if [[ "$1" == --jobs ]]; then jobs="$2"; fi
      prepare_args+=("$1" "$2")
      shift
      ;;
    --skip-deps | --force) prepare_args+=("$1") ;;
    -h | --help)
      cat <<'EOF'
Usage: ./Build-macOS.sh --rom-v77 PATH --rom-v80 PATH [options]

Prepare, build, test and package DKR-R.app on macOS.
  --rom-v77 PATH   US v1.0 ROM (or DKR_ROM_V77)
  --rom-v80 PATH   US Rev A/v1.1 ROM (or DKR_ROM_V80)
  --jobs N        Limit parallel build jobs (default: host CPU count)
  --skip-deps     Skip Homebrew installation
  --force         Regenerate payloads even when inputs are unchanged
  -h, --help      Show this help

Prerequisites: Xcode and Homebrew. Quote ROM paths with spaces.
Outputs: build/dkr-runtime-macos/bin/Release/DKR-R.app and a ZIP under dist/.
Launch with ./Run-macOS.sh.

Advanced: DKR_MAC_BUILD_DIR overrides the build directory; DKR_GENERATED_ROOT
overrides the payload directory. Set both DKR_MAC_GENERATED_SOURCE and
DKR_MAC_V80_GENERATED_SOURCE to use existing payloads and dependencies.
EOF
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done
jobs="${jobs:-$(sysctl -n hw.logicalcpu 2>/dev/null || echo 1)}"
[[ "$jobs" =~ ^[1-9][0-9]*$ ]] || {
  echo '--jobs must be a positive integer.' >&2
  exit 1
}
export CMAKE_BUILD_PARALLEL_LEVEL="$jobs"
[[ "$(uname -s)" == "Darwin" ]] || {
  echo 'Build-macOS.sh must run on macOS with Xcode command-line tools installed.' >&2
  exit 1
}

if [[ -z "${DKR_MAC_GENERATED_SOURCE:-}" || -z "${DKR_MAC_V80_GENERATED_SOURCE:-}" ]]; then
  # Apple's Bash 3.2 treats an empty array as unset under nounset.
  if [[ ${#prepare_args[@]} -gt 0 ]]; then
    "${project_root}/scripts/Prepare-DKR-Runtime-macOS.sh" "${prepare_args[@]}"
  else
    "${project_root}/scripts/Prepare-DKR-Runtime-macOS.sh"
  fi
  generated_root="${DKR_GENERATED_ROOT:-${project_root}/build/generated}"
  DKR_MAC_GENERATED_SOURCE="${generated_root}/v77/RecompiledFuncs"
  DKR_MAC_V80_GENERATED_SOURCE="${generated_root}/v80/RecompiledFuncs"
fi

for tool in cmake ninja ditto codesign; do
  command -v "${tool}" >/dev/null 2>&1 || {
    echo "Missing required macOS build tool: ${tool}" >&2
    exit 1
  }
done

generated_source="${DKR_MAC_GENERATED_SOURCE}"
[[ "$generated_source" == /* ]] || generated_source="$PWD/$generated_source"
[[ -d "${generated_source}" ]] || {
  echo "US v1.0/v77 Patch Pipeline output is missing: ${generated_source}" >&2
  exit 1
}

version="${DKR_RELEASE_VERSION:-$(tr -d '\r\n' <"${project_root}/VERSION")}"
[[ "$version" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || {
  echo 'Invalid release version.' >&2
  exit 1
}
host_arch="$(uname -m)"
architectures="${DKR_MAC_ARCHITECTURES:-${host_arch}}"
[[ "$architectures" =~ ^(arm64|x86_64)(\;(arm64|x86_64))*$ ]] || {
  echo 'Architectures must be arm64, x86_64, or a semicolon-separated list.' >&2
  exit 1
}
archive_arch="$(printf '%s' "${architectures}" | tr ';' '-')"
build_dir="${DKR_MAC_BUILD_DIR:-${project_root}/build/dkr-runtime-macos}"
revision_80_generated="${DKR_MAC_V80_GENERATED_SOURCE}"
[[ "$revision_80_generated" == /* ]] || revision_80_generated="$PWD/$revision_80_generated"
dist_dir="${project_root}/dist"
stage="${dist_dir}/DKR-R-${version}-macOS-${archive_arch}"
output="${stage}.zip"

[[ -n "${revision_80_generated}" && -d "${revision_80_generated}" ]] || {
  echo 'Set DKR_MAC_V80_GENERATED_SOURCE to Patch Pipeline output generated from the matching US Rev A/v1.1 ELF.' >&2
  exit 1
}

cmake -S "${project_root}/runtime-recomp" -B "${build_dir}" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_DEPLOYMENT_TARGET="${DKR_MACOS_DEPLOYMENT_TARGET:-12.0}" \
  -DCMAKE_OSX_ARCHITECTURES="${architectures}" \
  -DDKRPORT_ROOT="${project_root}" \
  -DDKR_RELEASE_VERSION="${version}" \
  -DDKR_RUNTIME_BUILD_GENERATED=ON \
  -DDKR_RUNTIME_BUILD_RT64=ON \
  -DDKR_GENERATED_SOURCE_V77="${generated_source}" \
  -DDKR_GENERATED_SOURCE_V80="${revision_80_generated}"
cmake --build "${build_dir}" --parallel "${jobs}"
ctest --test-dir "${build_dir}" --output-on-failure -R '^DKR'

built_app=""
while IFS= read -r candidate; do
  built_app="${candidate}"
  break
done < <(find "${build_dir}/bin" -type d -name 'DKR-R.app' -print)
[[ -n "${built_app}" && -x "${built_app}/Contents/MacOS/DKR-R" ]] || {
  echo "The macOS DKR-R.app bundle was not produced under ${build_dir}/bin." >&2
  exit 1
}

pak_test="$(mktemp -d "${TMPDIR:-/tmp}/dkr-r-pak-test.XXXXXX")"
cleanup() { rm -rf -- "${pak_test}"; }
trap cleanup EXIT
"${built_app}/Contents/MacOS/DKR-R" --self-test-pak "${pak_test}"

# Replace the staging output only after the build and tests succeed.
rm -rf -- "${stage}"
mkdir -p "${stage}"
ditto "${built_app}" "${stage}/DKR-R.app"
mkdir -p "${stage}/DKR-R.app/Contents/Resources/ThirdPartyLicenses"
install -m 0644 "${project_root}/assets/ui/Icons/DKR-R-Logo.bmp" \
  "${stage}/DKR-R.app/Contents/MacOS/assets/ui/Icons/DKR-R-Logo.bmp"
install -m 0644 "${project_root}/packaging/RELEASE-README.md" "${stage}/README.md"
install -m 0644 "${project_root}/LICENSE.md" "${stage}/LICENSE.md"
install -m 0644 "${project_root}/THIRD_PARTY.md" "${stage}/THIRD_PARTY.md"
install -m 0644 "${project_root}/runtime-recomp/COPYING-NOTICE.md" \
  "${stage}/COPYING-NOTICE.md"

notices="${stage}/DKR-R.app/Contents/Resources/ThirdPartyLicenses"
install -m 0644 "${project_root}/extern/rt64/LICENSE" "${notices}/RT64-LICENSE.txt"
install -m 0644 "${project_root}/extern/rt64/src/contrib/imgui/LICENSE.txt" \
  "${notices}/Dear-ImGui-LICENSE.txt"
install -m 0644 "${project_root}/extern/n64-modern-runtime/COPYING" \
  "${notices}/N64ModernRuntime-COPYING.txt"
install -m 0644 "${project_root}/extern/n64-modern-runtime/N64Recomp/LICENSE" \
  "${notices}/N64Recomp-LICENSE.txt"
install -m 0644 "${project_root}/extern/sdl2/LICENSE.txt" "${notices}/SDL2-LICENSE.txt"
install -m 0644 "${project_root}/packaging/licenses/Jumpman-LICENSE.txt" \
  "${notices}/Jumpman-LICENSE.txt"
install -m 0644 "${project_root}/packaging/licenses/Selawik-OFL.txt" \
  "${notices}/Selawik-OFL.txt"
install -m 0644 "${project_root}/packaging/licenses/CRT-FILTERS-NOTICE.md" \
  "${notices}/CRT-FILTERS-NOTICE.md"
install -m 0644 "${project_root}/packaging/licenses/GEKKONET-LICENSE.txt" \
  "${notices}/GEKKONET-LICENSE.txt"
install -m 0644 "${project_root}/packaging/licenses/MONOCYPHER-LICENSE.txt" \
  "${notices}/MONOCYPHER-LICENSE.txt"

# Generate a native icon from the approved DKR-R artwork when the standard
# macOS image utilities are available. The app remains valid without it.
if command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1 &&
  [[ -f "${project_root}/assets/ui/Icons/DKR-R-Icon.png" ]]; then
  iconset="${stage}/DKR-R.iconset"
  mkdir -p "${iconset}"
  for size in 16 32 128 256 512; do
    sips -z "${size}" "${size}" "${project_root}/assets/ui/Icons/DKR-R-Icon.png" \
      --out "${iconset}/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "${doubled}" "${doubled}" "${project_root}/assets/ui/Icons/DKR-R-Icon.png" \
      --out "${iconset}/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "${iconset}" -o \
    "${stage}/DKR-R.app/Contents/Resources/DKR-R.icns"
  rm -rf -- "${iconset}"
  /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconFile' \
    "${stage}/DKR-R.app/Contents/Info.plist" >/dev/null 2>&1 || true
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string DKR-R' \
    "${stage}/DKR-R.app/Contents/Info.plist"
fi

# Ad-hoc signing keeps the local bundle internally consistent. Public notarised
# releases can replace this signature in CI using an Apple Developer identity.
codesign --force --deep --sign - "${stage}/DKR-R.app"

while IFS= read -r -d '' file; do
  extension="${file##*.}"
  extension="$(printf '%s' "${extension}" | tr '[:upper:]' '[:lower:]')"
  case "${extension}" in
    z64 | v64 | n64 | eep | mpk | o2r | otr)
      echo "macOS release staging contains prohibited game data: ${file}" >&2
      exit 1
      ;;
  esac
  magic="$(od -An -tx1 -N4 "${file}" 2>/dev/null | tr -d '[:space:]')"
  case "${magic}" in
    80371240 | 37804012 | 40123780)
      echo "macOS release staging contains an N64 ROM header: ${file}" >&2
      exit 1
      ;;
  esac
done < <(find "${stage}" -type f -print0)

ditto -c -k --sequesterRsrc --keepParent "${stage}" "${output}"
printf '\nmacOS runtime, tests and app packaging passed.\n'
printf 'Graphics backend: RT64 Metal (native Apple path)\n'
printf 'Application: %s\n' "${stage}/DKR-R.app"
printf 'Archive: %s\n' "${output}"
shasum -a 256 "${output}"
