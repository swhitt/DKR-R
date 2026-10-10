# Building DKR-R 1.0.4

## Requirements

Windows preparation requires Visual Studio 2022 with Desktop development with
C++, Git, Python 3, PowerShell and WSL2/Ubuntu. Linux requires CMake 3.24+, Ninja,
Clang or GCC, Vulkan development files, Wayland/X11 development files and
AppImage packaging dependencies. The pinned SDL3 source used by the private
input helper is fetched by the preparation pipeline. You must supply supported
US v1.0 and US Rev A/v1.1 ROMs locally to produce both release engines.

## Prepare generated game code and dependencies

From a Windows terminal at the repository root:

```text
Build-DKR-Runtime.cmd
```

This validates the ROM, builds the matching decomp ELF, checks out the exact
dependency commits, applies `patches/manifest.json`, generates CPU/RSP sources
and runs the runtime probe. Generated and dependency worktrees are ignored and
must not be edited.

The release build consumes two internal engines but exposes one application.
Windows embeds the private Rev A engine in `DKR-R.exe`; Linux keeps it inside
the single AppImage and macOS inside `DKR-R.app`. The existing protected
`RecompiledFuncs` tree remains the v1.0/v77 output. Generate v1.1/v80 into a
separate build workspace, translate the versioned policy with
`scripts/generate_revision_policy.py`, create the N64Recomp configuration with
`scripts/generate_recomp_config.py`, and configure the second CMake tree with:

```text
-DDKR_GENERATED_SOURCE_V77=<v77-generated-directory>
-DDKR_GENERATED_SOURCE_V80=<v80-generated-directory>
```

CMake deliberately rejects attempts to compile v80 against the protected v77
generated directory.

Both revisions may instead be generated into an external workspace. Pass
`-GeneratedSource` to the Windows build, `DKR_LINUX_GENERATED_SOURCE` to the
Linux build, or `DKR_MAC_GENERATED_SOURCE` to the macOS build for the v77
output. The corresponding `*V80*GENERATED_SOURCE` option selects v80. This is
an option for keeping generated output outside the repository. On macOS,
the default one-command workflow below prepares both revisions automatically.

After a recomp policy change use:

```text
Diagnose-DKR-Recompile.cmd
```

## Windows release

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/Build-DKR-R-Windows.ps1 -Clean -Package
```

This configures a native Visual Studio x64 Release build, compiles the runtime,
runs the complete DKR-R CTest suite, executes the Controller Pak self-test,
scans the staged package and creates:

```text
dist/DKR-R-1.0.4-Windows-x64.zip
```

## Linux and AppImage

On Ubuntu or another supported build host:

```bash
./Setup-Linux.sh
./Build-Linux.sh
```

The build uses Vulkan through RT64, runs the complete DKR-R CTest suite and the
packaged Controller Pak self-test, then creates:

```text
dist/DKR-R-1.0.4-Linux-x86_64.AppImage
```

An unpackaged Linux binary is not a complete release deliverable. Both Patch
Pipeline outputs are mandatory so the single runtime can link the US v1.0 and
US v1.1 recompiled CPU payloads. Set `DKR_LINUX_V80_GENERATED_SOURCE` to the
matching v1.1 Patch Pipeline output before running `Build-Linux.sh`. On Windows,
`scripts/Build-DKR-R-Windows.ps1 -Package` accepts
`-Revision80GeneratedSource` or the `DKR_WINDOWS_V80_GENERATED_SOURCE`
environment variable.

Every package contains one `DKR-R` executable. Exact ROM identification selects
the matching recompiled payload in-process; both revisions always share the same
frontend, renderer, input system, runtime state and application window. The
packagers reject a release containing more than one public executable.

## macOS

On an Apple host with Xcode and Homebrew, one command
prepares and builds everything from your two ROMs:

Install Xcode and [Homebrew](https://brew.sh/) before the first build.
Open Xcode once to finish its setup. The build downloads Apple's Metal
toolchain if it is missing; Command Line Tools alone are insufficient.
If `xcode-select -p` still points to Command Line Tools, select Xcode with
`sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer`.

```bash
./Build-macOS.sh --rom-v77 "/path/to/US 1.0.z64" --rom-v80 "/path/to/US Rev A.z64"
```

`scripts/Prepare-DKR-Runtime-macOS.sh` runs first: it installs the Homebrew
tools, fetches and patches the pinned dependencies, builds N64Recomp, builds
each revision's matching decomp ELF in its own tree under `build/decomp`, and
generates both CPU payloads under `build/generated`. Unchanged ELFs and
payloads are reused, and native builds are incremental. Pass `--jobs 4` to
limit parallel builds, `--skip-deps` to leave Homebrew alone and `--force` to
rerun ELF preparation and payload generation. Prebuilt payloads
can be supplied with `DKR_MAC_GENERATED_SOURCE` and
`DKR_MAC_V80_GENERATED_SOURCE` instead of the ROM options; in that mode,
dependencies and build tools must already be prepared.

Both ROM revisions are needed to build the app; playing only needs one.
Launch the result with `./Run-macOS.sh`, or open the packaged `DKR-R.app`
under `dist/`. ROM paths containing spaces must be quoted as above.

The default build produces an app for the host architecture (Apple Silicon
`arm64` or Intel `x86_64`), targeting macOS 12 or later. Build and payload
directories can be changed with `DKR_MAC_BUILD_DIR` and `DKR_GENERATED_ROOT`.
Use the same `DKR_MAC_BUILD_DIR` when running `Run-macOS.sh`.
`DKR_ROM_V77` and `DKR_ROM_V80` can supply ROM paths instead of CLI options.
`./Build-macOS.sh --help` lists build options; `Setup-macOS.sh` is an optional
tool check, not a required preparation step.

The ZIP is written to `dist/DKR-R-<version>-macOS-<architecture>.zip`.
Package versions come from `VERSION`, or `DKR_RELEASE_VERSION` when set.
To create a source-only handoff kit, run `scripts/Package-macOS-Build-Kit.sh`
from a Git checkout. It includes tracked source and the dependency lockfile;
the recipient supplies both ROMs and runs the same build command.

RT64 uses Metal on macOS, and SDL2 is linked statically from `extern/sdl2`, so
`DKR-R.app` has no Homebrew runtime dependency. See
`packaging/MACOS-BUILD-README.md` for the handoff and validation checklist.

## Release safety

Run `python scripts/scan_for_game_assets.py` before packaging. No ROM, save,
Controller Pak, extracted asset, log, build cache or local configuration may be
included. Release archives are scanned again by their packaging scripts.
