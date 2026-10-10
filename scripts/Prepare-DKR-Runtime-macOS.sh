#!/usr/bin/env bash
# Prepare everything Build-macOS.sh compiles: pinned dependencies with their
# patches, N64Recomp, and the recompiled CPU payloads for both supported ROM
# revisions (US v1.0 = v77, US Rev A/v1.1 = v80). Re-running is cheap: each
# stage is skipped while its inputs are unchanged.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LOG_DIR="$PROJECT_ROOT/build-logs"
LOG_PATH="$LOG_DIR/prepare-dkr-runtime-$(date '+%Y%m%d-%H%M%S').log"
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_PATH") 2>&1

ROM_V77="${DKR_ROM_V77:-}"
ROM_V80="${DKR_ROM_V80:-}"
OUTPUT="${DKR_GENERATED_ROOT:-$PROJECT_ROOT/build/generated}"
SKIP_DEPS=0
FORCE=0
JOBS="$(sysctl -n hw.logicalcpu)"

usage() {
  cat <<EOF
Usage: $(basename "$0") --rom-v77 <US 1.0 ROM> --rom-v80 <US Rev A ROM> [options]
  --rom-v77 PATH   Diddy Kong Racing US v1.0 (.z64/.v64/.n64), or \$DKR_ROM_V77
  --rom-v80 PATH   Diddy Kong Racing US Rev A/v1.1, or \$DKR_ROM_V80
  --output DIR     Generated payload root (default: build/generated)
  --skip-deps      Don't install Homebrew packages
  --force          Regenerate every stage even if its inputs are unchanged
  --jobs N         Parallel jobs (default: $JOBS)
Writes <output>/v77/RecompiledFuncs and <output>/v80/RecompiledFuncs.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --rom-v77)
      ROM_V77="$2"
      shift
      ;;
    --rom-v80)
      ROM_V80="$2"
      shift
      ;;
    --output)
      OUTPUT="$2"
      shift
      ;;
    --skip-deps) SKIP_DEPS=1 ;;
    --force) FORCE=1 ;;
    --jobs)
      JOBS="$2"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
  shift
done

fail() {
  echo "[ERROR] $*" >&2
  echo "Full log: $LOG_PATH" >&2
  exit 1
}
step() {
  echo
  echo "==> $*"
}
[[ "$(uname -s)" == "Darwin" ]] || fail "This script prepares the macOS build."
[[ -n "$ROM_V77" && -f "$ROM_V77" ]] || {
  usage >&2
  fail "--rom-v77 must name your US v1.0 ROM."
}
[[ -n "$ROM_V80" && -f "$ROM_V80" ]] || {
  usage >&2
  fail "--rom-v80 must name your US Rev A/v1.1 ROM."
}

step "Host tools"
if [[ "$SKIP_DEPS" -eq 0 ]]; then
  command -v brew >/dev/null || fail "Homebrew is required: https://brew.sh/"
  brew install --quiet cmake ninja make llvm binutils python
fi
if command -v brew >/dev/null; then
  export PATH="$(brew --prefix llvm)/bin:$(brew --prefix binutils)/bin:$PATH"
  GMAKE="$(brew --prefix make)/bin/gmake"
else
  GMAKE="$(command -v gmake || true)"
fi
# macOS ships GNU Make 3.81; the decomp Makefile needs 4.x.
[[ -x "$GMAKE" ]] || fail "GNU Make 4 (gmake) is required: brew install make"
for tool in git python3 cmake ninja; do
  command -v "$tool" >/dev/null || fail "Required tool missing: $tool"
done
if ! xcrun metal -v >/dev/null 2>&1; then
  xcodebuild -downloadComponent MetalToolchain || fail "Install the Metal toolchain: xcodebuild -downloadComponent MetalToolchain"
fi

step "Pinned dependencies"
# Only fetch what isn't already at its pinned commit: patched checkouts are
# intentionally dirty and must not be reset on every run.
while IFS=$'\t' read -r name destination commit; do
  if [[ -e "$PROJECT_ROOT/$destination/.git" ]] &&
    [[ "$(git -C "$PROJECT_ROOT/$destination" rev-parse HEAD 2>/dev/null)" == "$commit" ]]; then
    echo "[OK] $name at ${commit:0:12}"
  elif [[ "$name" == "dkr-decomp" ]]; then
    "$SCRIPT_DIR/Prepare-Game-Source-macOS.sh"
  else
    python3 "$SCRIPT_DIR/bootstrap_dependencies.py" --only "$name"
  fi
done < <(
  python3 - "$PROJECT_ROOT/dependencies.lock.json" <<'PY'
import json, sys
for d in json.load(open(sys.argv[1]))["dependencies"]:
    print(d["name"], d["destination"], d["commit"], sep="\t")
PY
)
git -C "$PROJECT_ROOT/extern/dkr-decomp" submodule update --init --recursive

RT64="$PROJECT_ROOT/extern/rt64"
# The RT64 patches and runtime CMake expect metal-cpp at src/contrib/metal-cpp.
if [[ -d "$RT64/src/contrib/plume/contrib/metal-cpp" && ! -e "$RT64/src/contrib/metal-cpp" ]]; then
  ln -s plume/contrib/metal-cpp "$RT64/src/contrib/metal-cpp"
fi
# hlslpp's scalar fallback uses labs() without <stdlib.h>; AppleClang doesn't
# pull it in transitively. It's a submodule, so the patch pipeline can't own it.
HLSLPP_SCALAR="$RT64/src/contrib/hlslpp/include/hlsl++/platforms/scalar.h"
if [[ -f "$HLSLPP_SCALAR" ]] && ! grep -q '<stdlib.h>' "$HLSLPP_SCALAR"; then
  sed -i '' '/#include <stdint.h>/a\
#include <stdlib.h>' "$HLSLPP_SCALAR"
fi

step "Dependency patches"
python3 "$SCRIPT_DIR/apply_dependency_patches.py"

step "N64Recomp"
TOOL_BUILD="$PROJECT_ROOT/build/runtime-tools/n64recomp"
cmake -S "$PROJECT_ROOT/extern/n64-modern-runtime/N64Recomp" -B "$TOOL_BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$TOOL_BUILD" --parallel "$JOBS" --target N64RecompCLI
RECOMPILER="$TOOL_BUILD/N64Recomp"
[[ -x "$RECOMPILER" ]] || fail "N64Recomp was not built: $RECOMPILER"

step "Decomp toolchain"
DECOMP="$PROJECT_ROOT/extern/dkr-decomp"
if ! [[ -x "$DECOMP/tools/binutils/mips64-elf-as" ]] && ! command -v mips64-elf-as >/dev/null; then
  # The decomp's get-binutils.sh uses Linux-only nproc; build them here.
  version="binutils-2.46.0"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/dkr-binutils.XXXXXX")"
  trap 'rm -rf "$scratch"' EXIT
  curl -fsSL "https://ftp.gnu.org/gnu/binutils/$version.tar.xz" | tar -xJ -C "$scratch"
  (
    cd "$scratch/$version"
    ./configure --target=mips64-elf --prefix=/usr --with-sysroot=/usr/mips64-elf \
      --enable-64-bit-bfd --disable-gold --disable-nls --disable-shared --disable-werror \
      AR="$(brew --prefix llvm)/bin/llvm-ar" RANLIB="$(brew --prefix llvm)/bin/llvm-ranlib" >/dev/null
    make -j"$JOBS" >/dev/null
  ) || fail "Building MIPS binutils failed."
  mkdir -p "$DECOMP/tools/binutils"
  for pair in binutils/ar:ar binutils/objcopy:objcopy binutils/objdump:objdump \
    binutils/strip-new:strip gas/as-new:as ld/ld-new:ld; do
    cp "$scratch/$version/${pair%%:*}" "$DECOMP/tools/binutils/mips64-elf-${pair##*:}"
  done
fi
if ! [[ -x "$DECOMP/.venv/bin/python3" ]] || ! "$DECOMP/.venv/bin/python3" -c 'import splat' 2>/dev/null; then
  (cd "$DECOMP" && "$GMAKE" setup) || fail "Decomp setup failed."
fi

# stamp_matches <file> <value>: true when the stage's recorded inputs match.
stamp_matches() { [[ "$FORCE" -eq 0 && -f "$1" && "$(cat "$1")" == "$2" ]]; }

prepare_revision() {
  local revision="$1" rom="$2" sha1="$3" entrypoint="$4"
  local tree="$PROJECT_ROOT/build/decomp/v$revision"
  local elf="$tree/build/dkr.us.v$revision.elf" built_rom="$tree/build/dkr.us.v$revision.z64"
  local work="$OUTPUT/v$revision"

  step "US v$revision: ROM"
  # Normalise byte order and verify the exact retail dump.
  mkdir -p "$tree/baseroms"
  python3 - "$rom" "$tree/baseroms/baserom.us.v$revision.z64" "$sha1" <<'PY'
import hashlib, pathlib, sys
source, target, expected = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
data = bytearray(source.read_bytes())
magic = bytes(data[:4]).hex()
if magic == "37804012":
    data[0::2], data[1::2] = data[1::2], data[0::2]
elif magic == "40123780":
    for i in range(0, len(data) - 3, 4):
        data[i:i + 4] = data[i:i + 4][::-1]
elif magic != "80371240":
    raise SystemExit(f"{source}: not an N64 ROM (magic {magic})")
digest = hashlib.sha1(data).hexdigest()
if digest != expected:
    raise SystemExit(f"{source}: SHA-1 {digest}, expected {expected}")
if not target.exists() or target.read_bytes() != data:
    target.write_bytes(data)
print(f"[OK] {source.name} verified ({digest})")
PY

  step "US v$revision: decomp ELF"
  # Each revision gets its own tree: the decomp extracts every version into
  # the same asm/, assets/ and build/ directories.
  local decomp_commit
  decomp_commit="$(git -C "$DECOMP" rev-parse HEAD)"
  if stamp_matches "$tree/.dkr-elf-stamp" "$decomp_commit $sha1" && [[ -f "$elf" ]]; then
    echo "[OK] up to date: $elf"
  else
    rsync -a --delete --exclude /build --exclude /asm --exclude /assets \
      --exclude /baseroms --exclude /.dkr-elf-stamp "$DECOMP/" "$tree/"
    (cd "$tree" && "$GMAKE" VERSION="v$revision" extract && "$GMAKE" VERSION="v$revision" -j"$JOBS") ||
      fail "The US v$revision decomp build failed."
    echo "$decomp_commit $sha1" >"$tree/.dkr-elf-stamp"
  fi

  step "US v$revision: recompiled payload"
  local inputs
  inputs="$(cat "$PROJECT_ROOT"/runtime-recomp/*.v"$revision".*.json "$PROJECT_ROOT"/scripts/*.py \
    "$elf" "$RECOMPILER" | shasum -a 256 | cut -d' ' -f1)"
  if stamp_matches "$work/.dkr-payload-stamp" "$inputs" && [[ -f "$work/RecompiledFuncs/funcs.h" ]]; then
    echo "[OK] up to date: $work/RecompiledFuncs"
    return
  fi
  rm -rf "$work"
  mkdir -p "$work/RecompiledFuncs"
  python3 "$SCRIPT_DIR/compose_legacy_mod_policy.py" \
    --policy "$PROJECT_ROOT/runtime-recomp/dkr.us.v$revision.recomp-policy.json" \
    --fragment "$PROJECT_ROOT/runtime-recomp/legacy-mods.v$revision.recomp-fragment.json" \
    --track-menu "$PROJECT_ROOT/runtime-recomp/legacy-track-menu.v$revision.recomp-fragment.json" \
    --characters "$PROJECT_ROOT/runtime-recomp/legacy-characters.v$revision.recomp-fragment.json" \
    --character-menu "$PROJECT_ROOT/runtime-recomp/legacy-character-menu.v$revision.recomp-fragment.json" \
    --scene-runtime --elf "$elf" --output "$work/policy.json"
  python3 "$SCRIPT_DIR/generate_recomp_config.py" \
    --policy "$work/policy.json" --elf "$elf" --rom "$built_rom" \
    --output-functions "$work/RecompiledFuncs" --entrypoint "$entrypoint" \
    --output "$work/dkr.us.v$revision.toml"
  (cd "$PROJECT_ROOT/runtime-recomp" && "$RECOMPILER" "$work/dkr.us.v$revision.toml") \
    >"$work/n64recomp.log" 2>&1 || {
    tail -20 "$work/n64recomp.log"
    fail "N64Recomp failed for v$revision."
  }
  echo "$inputs" >"$work/.dkr-payload-stamp"
  echo "[OK] $work/RecompiledFuncs"
}

# Entrypoints are mainproc in each retail image.
prepare_revision 77 "$ROM_V77" 0cb115d8716dbbc2922fda38e533b9fe63bb9670 0x80065D40
prepare_revision 80 "$ROM_V80" 6d96743d46f8c0cd0edb0ec5600b003c89b93755 0x80065F80

echo
echo "[OK] Payloads ready in $OUTPUT"
echo "Full log: $LOG_PATH"
