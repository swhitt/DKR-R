# External dependencies

Dependency worktrees are created locally and are intentionally absent from
source archives. Exact repositories and commits are recorded in
`dependencies.lock.json`; project changes are applied only through the
checksummed Patch Pipeline in `patches/manifest.json`.

Use `Build-DKR-Runtime.cmd` on Windows or `Build-macOS.sh` with both ROM paths
on macOS for a complete prepared checkout. See [the build guide](../docs/BUILDING.md).
Do not edit,
commit or distribute dependency worktrees from this directory.
