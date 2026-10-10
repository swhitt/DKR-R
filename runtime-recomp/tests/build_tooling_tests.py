#!/usr/bin/env python3
"""Zero-dependency tests for the build tooling: the dependency patch pipeline,
the reviewed-ELF image digest, and repository contracts the shell build
entry points rely on. Needs only git and Python."""

import hashlib
import json
import os
import re
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))

import apply_dependency_patches as patches  # noqa: E402
import legacy_character_presentation_policy as presentation  # noqa: E402


def git(repo, *args):
    return subprocess.run(["git", "-C", str(repo), *args], check=True,
                          capture_output=True, text=True).stdout.strip()


class PatchPipelineTests(unittest.TestCase):
    """Stacked patches where the second edits the first's file and adds a new
    one, which is exactly what broke the old all-or-reset logic."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        upstream = self.root / "upstream"
        upstream.mkdir()
        git(upstream, "init", "-q")
        git(upstream, "config", "user.email", "t@example.invalid")
        git(upstream, "config", "user.name", "t")
        (upstream / "a.txt").write_text("one\ntwo\nthree\n")
        (upstream / "unrelated.txt").write_text("original\n")
        git(upstream, "add", ".")
        git(upstream, "commit", "-qm", "base")
        self.commit = git(upstream, "rev-parse", "HEAD")

        def make_patch(name, edit):
            edit(upstream)
            git(upstream, "add", "-A")
            diff = git(upstream, "diff", "--cached", "--binary") + "\n"
            git(upstream, "commit", "-qm", name)
            path = self.root / "patches" / f"{name}.patch"
            path.parent.mkdir(exist_ok=True)
            path.write_text(diff)
            return path

        first = make_patch("0001", lambda r: (r / "a.txt").write_text("one\nTWO\nthree\n"))
        second = make_patch("0002", lambda r: ((r / "a.txt").write_text("one\nTWO\nTHREE\n"),
                                               (r / "new.txt").write_text("created\n")))
        self.final_a = "one\nTWO\nTHREE\n"
        self.patches = [first, second]
        # The dependency is checked out through `git worktree`, giving it a
        # .git *file* like a submodule (the old pipeline skipped those).
        self.repo = self.root / "dep"
        git(upstream, "worktree", "add", "-q", "--detach", str(self.repo), self.commit)
        self.manifest = self.root / "manifest.json"
        self.manifest.write_text(json.dumps({"schemaVersion": 1, "dependencies": [{
            "name": "dep", "repositoryPath": "dep", "expectedCommit": self.commit,
            "patches": [{"path": str(p.relative_to(self.root)),
                         "sha256": hashlib.sha256(p.read_bytes()).hexdigest()}
                        for p in self.patches]}]}))

    def tearDown(self):
        self.temp.cleanup()

    def apply(self):
        return patches.apply_manifest(self.root, self.manifest)

    def assert_patched(self):
        self.assertEqual((self.repo / "a.txt").read_text(), self.final_a)
        self.assertEqual((self.repo / "new.txt").read_text(), "created\n")

    def test_submodule_style_checkout_is_patched(self):
        self.assertTrue((self.repo / ".git").is_file())
        self.apply()
        self.assert_patched()

    def test_rerun_is_a_no_op(self):
        self.apply()
        stamp = (self.repo / "a.txt").stat().st_mtime_ns
        os.utime(self.repo / "a.txt", ns=(stamp - 10**9, stamp - 10**9))
        stamp = (self.repo / "a.txt").stat().st_mtime_ns
        self.apply()
        self.assertEqual((self.repo / "a.txt").stat().st_mtime_ns, stamp)
        self.assert_patched()

    def test_half_applied_checkout_is_repaired(self):
        # First patch applied, plus the second patch's new file left behind
        # by an interrupted run (`git checkout -- .` doesn't remove it).
        git(self.repo, "apply", str(self.patches[0]))
        (self.repo / "new.txt").write_text("stale\n")
        self.apply()
        self.assert_patched()

    def test_local_edit_is_reverted_and_unrelated_untracked_kept(self):
        self.apply()
        (self.repo / "a.txt").write_text("local edit\n")
        (self.repo / "helper-symlink-target").write_text("keep me\n")
        self.apply()
        self.assert_patched()
        self.assertEqual((self.repo / "helper-symlink-target").read_text(), "keep me\n")

    def test_checksum_and_commit_are_enforced(self):
        self.patches[0].write_text(self.patches[0].read_text() + "\n")
        with self.assertRaises(SystemExit):
            self.apply()

    def test_unrelated_tracked_edit_is_preserved(self):
        (self.repo / "unrelated.txt").write_text("developer edit\n")
        with self.assertRaisesRegex(SystemExit, "local edits outside the patch set"):
            self.apply()
        self.assertEqual((self.repo / "unrelated.txt").read_text(), "developer edit\n")
        self.assertEqual((self.repo / "a.txt").read_text(), "one\ntwo\nthree\n")


def elf32be(sections):
    """Minimal big-endian ELF32 with the given (name, type, flags, addr, data)."""
    names = b"\0" + b"".join(n.encode() + b"\0" for n, *_ in sections) + b".shstrtab\0"
    body, offsets, cursor = b"", [], 52
    for _, kind, _, _, data in sections:
        offsets.append(cursor)
        if kind != 8:
            body += data
            cursor += len(data)
    shstr_offset = cursor
    body += names
    cursor += len(names)
    headers = b"\0" * 40
    name_at = 1
    for (name, kind, flags, addr, data), offset in zip(sections, offsets):
        headers += struct.pack(">10I", name_at, kind, flags, addr, offset, len(data), 0, 0, 4, 0)
        name_at += len(name) + 1
    headers += struct.pack(">10I", name_at, 3, 0, 0, shstr_offset, len(names), 0, 0, 1, 0)
    count = len(sections) + 2
    header = b"\x7fELF\x01\x02\x01" + b"\0" * 9 + struct.pack(
        ">HHIIIIIHHHHHH", 2, 8, 1, 0, 0, cursor, 0, 52, 0, 0, 40, count, count - 1)
    return header + body + headers


class ElfImageDigestTests(unittest.TestCase):
    def digest(self, sections):
        with tempfile.NamedTemporaryFile(suffix=".elf", delete=False) as handle:
            handle.write(elf32be(sections))
        try:
            return presentation.elf_image_digest(Path(handle.name))
        finally:
            os.unlink(handle.name)

    def base(self, symtab=b"\0" * 16, code=b"\x27\xbd\xff\xe0", bss=8):
        return [(".main", 1, 6, 0x80000400, code),
                (".bss", 8, 3, 0x80100000, b"\0" * bss),
                (".symtab", 2, 0, 0, symtab)]

    def test_symbol_table_differences_are_ignored(self):
        self.assertEqual(self.digest(self.base()), self.digest(self.base(symtab=b"\1" * 32)))

    def test_code_and_layout_changes_are_detected(self):
        reference = self.digest(self.base())
        self.assertNotEqual(reference, self.digest(self.base(code=b"\x27\xbd\xff\xd8")))
        self.assertNotEqual(reference, self.digest(self.base(bss=16)))

    def test_non_elf_is_rejected(self):
        with tempfile.NamedTemporaryFile(delete=False) as handle:
            handle.write(b"not an elf")
        try:
            with self.assertRaises(ValueError):
                presentation.elf_image_digest(Path(handle.name))
        finally:
            os.unlink(handle.name)


class RepositoryContractTests(unittest.TestCase):
    @unittest.skipUnless(Path("/bin/bash").exists(), "requires system Bash")
    def test_build_prepares_without_cli_arguments_in_system_bash(self):
        # macOS ships Bash 3.2: expanding an empty array under set -u fails.
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "scripts").mkdir()
            (root / "bin").mkdir()
            build = root / "Build-macOS.sh"
            build.write_text((ROOT / "Build-macOS.sh").read_text())
            prepare = root / "scripts" / "Prepare-DKR-Runtime-macOS.sh"
            prepare.write_text('#!/bin/sh\necho "prepare called"\nexit 42\n')
            prepare.chmod(0o755)
            uname = root / "bin" / "uname"
            uname.write_text('#!/bin/sh\necho Darwin\n')
            uname.chmod(0o755)
            env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"],
                       CMAKE_BUILD_PARALLEL_LEVEL="1")
            env.pop("DKR_MAC_GENERATED_SOURCE", None)
            env.pop("DKR_MAC_V80_GENERATED_SOURCE", None)
            result = subprocess.run(["/bin/bash", str(build)], env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 42, result.stdout + result.stderr)
            self.assertIn("prepare called", result.stdout)

    def test_macos_option_errors_are_actionable(self):
        for script in ("Build-macOS.sh", "scripts/Prepare-DKR-Runtime-macOS.sh"):
            for option in ("--rom-v77", "--rom-v80", "--jobs"):
                with self.subTest(script=script, option=option):
                    result = subprocess.run(["bash", str(ROOT / script), option],
                                            capture_output=True, text=True)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("requires", result.stdout + result.stderr)
                    self.assertNotIn("unbound variable", result.stdout + result.stderr)

    def tracked(self):
        output = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-s"], check=True,
                                capture_output=True, text=True).stdout
        for line in output.splitlines():
            mode, _, _, path = line.split(maxsplit=3)
            yield mode, path

    def test_macos_shell_entry_points_are_executable(self):
        if not (ROOT / ".git").exists():
            self.skipTest("not a git checkout")
        entry_points = {
            "Build-macOS.sh", "Run-macOS.sh", "Setup-macOS.sh",
            "scripts/Prepare-DKR-Runtime-macOS.sh",
            "scripts/Prepare-Game-Source-macOS.sh",
            "scripts/Package-macOS-Build-Kit.sh",
            "scripts/apply-dependency-patches.sh",
        }
        missing = [p for mode, p in self.tracked() if p in entry_points and mode != "100755"]
        self.assertEqual(missing, [], "commit with: git update-index --chmod=+x <file>")

    def test_shell_script_references_match_on_disk_case(self):
        # macOS defaults to case-insensitive APFS, Linux CI does not.
        names = {p.name for p in (ROOT / "scripts").iterdir()}
        lower = {n.lower(): n for n in names}
        wrong = []
        for script in list(ROOT.glob("*.sh")) + list((ROOT / "scripts").glob("*.sh")):
            for ref in re.findall(r"scripts/([A-Za-z0-9_.-]+\.(?:sh|py))", script.read_text()):
                if ref not in names and ref.lower() in lower:
                    wrong.append(f"{script.name}: {ref} -> {lower[ref.lower()]}")
        self.assertEqual(wrong, [])


if __name__ == "__main__":
    unittest.main()
