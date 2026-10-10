#!/usr/bin/env bash
set -euo pipefail
for tool in cmake ninja c++; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Missing required tool: $tool" >&2
    echo "Install Xcode and open it once to finish setup." >&2
    echo "Install CMake and Ninja with: brew install cmake ninja" >&2
    exit 1
  fi
done
if ! xcrun --find metal >/dev/null 2>&1; then
  echo "Install MetalToolchain with: xcodebuild -downloadComponent MetalToolchain"
  exit 1
fi
cmake --version | head -n1
c++ --version | head -n1
echo 'macOS setup checks passed. Run ./Build-macOS.sh --rom-v77 "/path/to/US 1.0.z64" --rom-v80 "/path/to/US Rev A.z64".'
