"""Tiny owned-stage fixtures only: no network, Rust build, provider, or app."""
from contextlib import contextmanager
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import tomllib
import unittest
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("managed_codex_build", ROOT / "scripts/build-managed-codex-host.py")
BUILD = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = BUILD
SPEC.loader.exec_module(BUILD)


def git_hash(kind, data):
    return hashlib.sha1(kind.encode() + b" " + str(len(data)).encode() + b"\0" + data).hexdigest()


def tree_for(files, modes=None):
    entries = {}
    for name, data in files.items():
        entries[name] = {"path": name, "mode": (modes or {}).get(name, "100644"), "type": "blob",
                         "sha": git_hash("blob", data), "size": len(data)}
        parent = Path(name).parent
        while str(parent) != ".":
            entries.setdefault(parent.as_posix(), {"path": parent.as_posix(), "mode": "040000", "type": "tree"})
            parent = parent.parent

    def digest(parent):
        children = [value for name, value in entries.items()
                    if str(Path(name).parent) == (parent or ".")]
        data = b""
        for child in sorted(children, key=lambda item: Path(item["path"]).name +
                            ("/" if item["type"] == "tree" else "")):
            if child["type"] == "tree":
                child["sha"] = digest(child["path"])
            data += (child["mode"].lstrip("0") + " " + Path(child["path"]).name).encode()
            data += b"\0" + bytes.fromhex(child["sha"])
        return git_hash("tree", data)

    root = digest("")
    return {"sha": BUILD.UPSTREAM_COMMIT, "truncated": False, "tree": list(entries.values())}, root


def archive_for(files, extra=None, modes=None):
    data = io.BytesIO()
    with tarfile.open(fileobj=data, mode="w:gz") as archive:
        for name, content in list(files.items()) + ([] if extra is None else [extra]):
            info = tarfile.TarInfo("codex-fixture/" + name)
            mode = (modes or {}).get(name, "100644")
            if mode == "120000":
                info.type = tarfile.SYMTYPE
                info.linkname = content.decode()
                archive.addfile(info)
            else:
                info.size = len(content)
                info.mode = 0o755 if mode == "100755" else 0o644
                archive.addfile(info, io.BytesIO(content))
    return data.getvalue()


class ManagedCodexBuildTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="cmux-managed-codex-stage-unit-")).resolve()
        print(f"Retained tiny stage fixture: {self.root}", file=sys.stderr)
        self.files = {
            "codex-rs/Cargo.toml": b'[workspace]\nmembers = ["app-server"]\nresolver = "2"\n'
                b'[workspace.package]\nversion = "0.154.0"\n'
                b'[workspace.dependencies]\nserde = "1.0"\n',
            "codex-rs/Cargo.lock": b'version = 4\n\n[[package]]\nname = "codex-app-server"\n'
                b'version = "0.154.0"\ndependencies = ["serde"]\n\n'
                b'[[package]]\nname = "serde"\nversion = "1.0.0"\nsource = "registry+fixture"\nchecksum = "abc"\n',
            "codex-rs/rust-toolchain.toml": b'[toolchain]\nchannel = "1.95.0"\n',
            "codex-rs/app-server/src/in_process.rs": b"pub fn ordinary() -> bool { false }\n",
            "LICENSE": b"fixture license\n",
        }
        self.tree, root_tree = tree_for(self.files)
        self.pins = patch.object(BUILD, "UPSTREAM_TREE", root_tree)
        self.pins.start()
        self.addCleanup(self.pins.stop)
        tree = patch.object(BUILD, "_fetch_tree", return_value=self.tree)
        self.fetch_tree = tree.start()
        self.addCleanup(tree.stop)
        archive = patch.object(BUILD, "_fetch_archive", return_value=archive_for(self.files))
        self.fetch_archive = archive.start()
        self.addCleanup(archive.stop)

    def source(self):
        return BUILD.acquire_sdk(self.root / "source")

    def member(self):
        member = self.root / "member"
        (member / "src").mkdir(parents=True)
        (member / "Cargo.toml").write_text(
            '[package]\nname = "cmux-managed-codex-host"\nversion = "0.1.0"\nedition = "2024"\n'
            '[dependencies]\nserde = { workspace = true }\n'
        )
        (member / "src/main.rs").write_text("fn main() {}\n")
        return member

    def compiler(self, *, version="1.95.0", change_lock=False):
        rust = self.root / "rust"
        rust.mkdir()
        for name in ("cargo", "rustc", "rustdoc"):
            tool = rust / name
            tool.write_text(
                f"#!{sys.executable}\n"
                "import json,os,sys\nfrom pathlib import Path\n"
                f"if sys.argv[1:] == ['--version']: print({name!r} + ' {version} (fixture)')\n"
                "else:\n"
                f" Path({str(self.root / 'compiler-call.json')!r}).write_text(json.dumps("
                "{'args':sys.argv[1:],'cwd':os.getcwd(),'target':os.environ['CARGO_TARGET_DIR'],"
                "'rustc':os.environ['RUSTC'],'incremental':os.environ.get('CARGO_INCREMENTAL'),"
                "'dev_debug':os.environ.get('CARGO_PROFILE_DEV_DEBUG'),"
                "'test_debug':os.environ.get('CARGO_PROFILE_TEST_DEBUG')}))\n"
                + (" Path('Cargo.lock').write_bytes(Path('Cargo.lock').read_bytes()+b'\\n')\n"
                   if change_lock else "")
            )
            tool.chmod(0o700)
        return rust

    @contextmanager
    def release_source(self, *, count=150, version="0.0.0", duplicate=False, malformed=False):
        blocks = []
        for index in range(count):
            name = "codex-app-server" if index == 0 else f"codex-local-{index:03d}"
            if duplicate and index == 1:
                name = "codex-app-server"
            if malformed and index == 0:
                name = ""
            blocks.append(f'[[package]]\nname = "{name}"\nversion = "{version}"\n'
                          'dependencies = ["serde"]\n')
        lock = ('# retained source comment\nversion = 4\n\n' + "\n".join(blocks)
                + '\n[[package]]\nname = "serde"\nversion = "1.0.0"\n'
                'source = "registry+fixture"\nchecksum = "abc"\n').encode()
        files = dict(self.files, **{"codex-rs/Cargo.lock": lock})
        tree, root_tree = tree_for(files)
        with patch.object(BUILD, "UPSTREAM_TREE", root_tree), \
             patch.object(BUILD, "RELEASE_MANIFEST_BLOB",
                          git_hash("blob", files["codex-rs/Cargo.toml"]), create=True), \
             patch.object(BUILD, "RELEASE_LOCK_BLOB", git_hash("blob", lock), create=True), \
             patch.object(BUILD, "_fetch_tree", return_value=tree), \
             patch.object(BUILD, "_fetch_archive", return_value=archive_for(files)):
            destination = self.root / f"source-release-{len(list(self.root.iterdir()))}"
            yield BUILD.acquire_sdk(destination)

    def test_release_lock_projection_preserves_source_external_graph_and_other_bytes(self):
        with self.release_source() as source:
            original = (source.root / "codex-rs/Cargo.lock").read_bytes()
            stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
            actual = (stage.root / "codex-rs/Cargo.lock").read_bytes()
            upstream = tomllib.loads(original.decode())
            projected = tomllib.loads(actual.decode())
            local = [item for item in projected["package"] if "source" not in item]
            self.assertEqual(len(local), 150)
            self.assertEqual({item["version"] for item in local}, {"0.154.0"})
            self.assertEqual(actual, original.replace(b'version = "0.0.0"', b'version = "0.154.0"'))
            self.assertEqual((source.root / "codex-rs/Cargo.lock").read_bytes(), original)
            self.assertEqual((stage.root / "codex-rs/Cargo.toml").read_bytes(),
                             self.files["codex-rs/Cargo.toml"])
            self.assertEqual([item for item in projected["package"] if "source" in item],
                             [item for item in upstream["package"] if "source" in item])
            for before, after in zip(upstream["package"], projected["package"]):
                self.assertEqual({key: value for key, value in before.items() if key != "version"},
                                 {key: value for key, value in after.items() if key != "version"})
            owner = json.loads((stage.root / BUILD.STAGE_OWNER).read_text())
            proof = owner["release_lock_projection"]
            self.assertEqual(proof["original_lock_sha256"], hashlib.sha256(original).hexdigest())
            self.assertEqual(proof["projected_lock_sha256"], hashlib.sha256(actual).hexdigest())
            self.assertEqual(len(proof["local_packages"]), 150)
            self.assertEqual(proof["local_packages"]["codex-app-server"],
                             {"from": "0.0.0", "to": "0.154.0"})
            self.assertEqual(BUILD._stage(stage.root), stage)

    def test_release_lock_projection_composes_member_and_compiler_receipt(self):
        with self.release_source() as source:
            stage = BUILD.prepare_stage(source.root, self.root / "stage", self.member(), None)
            packages = tomllib.loads((stage.root / "codex-rs/Cargo.lock").read_text())["package"]
            self.assertEqual(next(item for item in packages if item["name"] == BUILD.MEMBER)["version"],
                             "0.1.0")
            self.assertEqual({item["version"] for item in packages
                              if "source" not in item and item["name"] != BUILD.MEMBER}, {"0.154.0"})
            with patch.object(BUILD, "_free_bytes", return_value=61 * 1024**3):
                result = BUILD.run_locked(stage, self.root / "target", self.compiler(),
                                          ["test", "-p", BUILD.MEMBER])
            owner = json.loads((stage.root / BUILD.STAGE_OWNER).read_text())
            receipt = json.loads(result.receipt.read_text())
            self.assertEqual(receipt["release_lock_projection"], owner["release_lock_projection"])
            self.assertIn("--locked", receipt["command"])
            self.assertFalse(receipt["qualification"])

    def test_release_lock_projection_refuses_mixed_pair_before_writes(self):
        with self.release_source() as source:
            for name in ("RELEASE_MANIFEST_BLOB", "RELEASE_LOCK_BLOB"):
                destination = self.root / name
                with patch.object(BUILD, name, "0" * 40):
                    with self.assertRaises(BUILD.BuildError):
                        BUILD.prepare_stage(source.root, destination, None, None)
                self.assertFalse(destination.exists())

    def test_release_lock_projection_refuses_invalid_local_records_before_writes(self):
        for index, options in enumerate((
                {"count": 149}, {"version": "0.0.1"}, {"duplicate": True}, {"malformed": True})):
            with self.subTest(options=options), self.release_source(**options) as source:
                destination = self.root / f"bad-release-{index}"
                with self.assertRaises(BUILD.BuildError):
                    BUILD.prepare_stage(source.root, destination, None, None)
                self.assertFalse(destination.exists())

    def test_release_lock_projection_metadata_is_revalidated_without_mutation(self):
        with self.release_source() as source:
            stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
            owner_path = stage.root / BUILD.STAGE_OWNER
            owner = json.loads(owner_path.read_text())
            owner["release_lock_projection"] = {"local_packages": {}, "qualification": True}
            owner_path.write_text(json.dumps(owner))
            before = {path: path.read_bytes() for path in (owner_path, stage.root / "codex-rs/Cargo.lock")}
            with self.assertRaises(BUILD.BuildError):
                BUILD.prepare_stage(source.root, stage.root, None, None)
            self.assertEqual({path: path.read_bytes() for path in before}, before)

    def test_release_lock_projection_rejects_external_drift_even_with_rewritten_inventory(self):
        with self.release_source() as source:
            stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
            lock = stage.root / "codex-rs/Cargo.lock"
            lock.write_bytes(lock.read_bytes().replace(b'checksum = "abc"', b'checksum = "foreign"'))
            owner_path = stage.root / BUILD.STAGE_OWNER
            owner = json.loads(owner_path.read_text())
            owner["files"] = BUILD._snapshot(stage.root, [BUILD.STAGE_OWNER])
            owner_path.write_text(json.dumps(owner))
            changed = lock.read_bytes()
            with self.assertRaises(BUILD.BuildError):
                BUILD.prepare_stage(source.root, stage.root, None, None)
            self.assertEqual(lock.read_bytes(), changed)

    def test_release_lock_projection_refuses_preprojection_stage_without_migrating(self):
        with self.release_source() as source:
            stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
            lock = stage.root / "codex-rs/Cargo.lock"
            lock.write_bytes((source.root / "codex-rs/Cargo.lock").read_bytes())
            owner_path = stage.root / BUILD.STAGE_OWNER
            owner = json.loads(owner_path.read_text())
            owner.pop("release_lock_projection", None)
            owner["files"] = BUILD._snapshot(stage.root, [BUILD.STAGE_OWNER])
            owner_path.write_text(json.dumps(owner))
            before = owner_path.read_bytes(), lock.read_bytes()
            with self.assertRaises(BUILD.BuildError):
                BUILD.prepare_stage(source.root, stage.root, None, None)
            self.assertEqual((owner_path.read_bytes(), lock.read_bytes()), before)

    def test_release_lock_projection_leaves_already_consistent_fixture_unchanged(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        self.assertEqual((stage.root / "codex-rs/Cargo.lock").read_bytes(),
                         self.files["codex-rs/Cargo.lock"])
        self.assertIsNone(json.loads((stage.root / BUILD.STAGE_OWNER).read_text()).get(
            "release_lock_projection"))

    def test_acquisition_is_complete_exact_and_does_not_rewrite_existing_source(self):
        source = self.source()
        self.assertEqual(source.commit, BUILD.UPSTREAM_COMMIT)
        self.assertEqual(set(source.files), set(self.files))
        for name, data in self.files.items():
            self.assertEqual((source.root / name).read_bytes(), data)
        with self.assertRaises(BUILD.BuildError):
            BUILD.acquire_sdk(source.root)

    def test_acquisition_rejects_archive_escape_or_blob_drift_before_destination_writes(self):
        for name, archive in [
            ("escape", archive_for(self.files, ("../../outside", b"bad"))),
            ("drift", archive_for(dict(self.files, LICENSE=b"changed\n"))),
            ("missing", archive_for({k: v for k, v in self.files.items() if k != "LICENSE"})),
        ]:
            with self.subTest(name=name):
                self.fetch_archive.return_value = archive
                destination = self.root / name
                with self.assertRaises(BUILD.BuildError):
                    BUILD.acquire_sdk(destination)
                self.assertFalse(destination.exists())
        self.assertFalse((self.root / "outside").exists())

    def test_acquisition_rejects_truncated_or_foreign_tree(self):
        self.fetch_tree.return_value = dict(self.tree, truncated=True)
        with self.assertRaises(BUILD.BuildError):
            self.source()
        self.fetch_tree.return_value = dict(self.tree, sha="0" * 40)
        with self.assertRaises(BUILD.BuildError):
            self.source()

    def test_acquisition_preserves_pinned_internal_symlink_and_executable_modes(self):
        files = dict(self.files, **{"license-link": b"LICENSE", "script.sh": b"#!/bin/sh\nexit 0\n"})
        modes = {"license-link": "120000", "script.sh": "100755"}
        tree, root_tree = tree_for(files, modes)
        self.fetch_tree.return_value = tree
        self.fetch_archive.return_value = archive_for(files, modes=modes)
        with patch.object(BUILD, "UPSTREAM_TREE", root_tree):
            source = self.source()
            self.assertTrue((source.root / "license-link").is_symlink())
            self.assertEqual((source.root / "license-link").read_bytes(), self.files["LICENSE"])
            self.assertTrue((source.root / "script.sh").stat().st_mode & stat.S_IXUSR)
            stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
            self.assertTrue((stage.root / "license-link").is_symlink())

    def test_acquisition_refuses_even_a_git_pinned_escaping_symlink(self):
        files = dict(self.files, **{"license-link": b"../outside"})
        modes = {"license-link": "120000"}
        tree, root_tree = tree_for(files, modes)
        self.fetch_tree.return_value = tree
        self.fetch_archive.return_value = archive_for(files, modes=modes)
        with patch.object(BUILD, "UPSTREAM_TREE", root_tree), self.assertRaises(BUILD.BuildError):
            self.source()
        self.assertFalse((self.root / "source").exists())

    def test_stage_refuses_foreign_or_symlinked_owner_without_mutation(self):
        source = self.source()
        foreign = self.root / "foreign"
        foreign.mkdir()
        sentinel = foreign / "keep"
        sentinel.write_bytes(b"foreign generation")
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, foreign, None, None)
        self.assertEqual(list(foreign.iterdir()), [sentinel])
        self.assertEqual(sentinel.read_bytes(), b"foreign generation")
        link = self.root / "symlink"
        link.symlink_to(foreign, target_is_directory=True)
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, link, None, None)
        self.assertEqual(sentinel.read_bytes(), b"foreign generation")

    def test_stage_rejects_source_or_stage_lock_drift_without_touching_other_files(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        lock = stage.root / "codex-rs/Cargo.lock"
        lock.write_bytes(lock.read_bytes().replace(b'1.0.0', b'2.0.0'))
        changed = lock.read_bytes()
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, stage.root, None, None)
        self.assertEqual(lock.read_bytes(), changed)
        (source.root / "LICENSE").write_text("source drift")
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, self.root / "new-stage", None, None)
        self.assertFalse((self.root / "new-stage").exists())

    def test_stage_preserves_upstream_lock_and_updates_only_member_and_declared_patch_paths(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        member = self.member()
        owned_patch = self.root / "owned.patch"
        owned_patch.write_text(
            "diff --git a/codex-rs/app-server/src/in_process.rs b/codex-rs/app-server/src/in_process.rs\n"
            "--- a/codex-rs/app-server/src/in_process.rs\n+++ b/codex-rs/app-server/src/in_process.rs\n"
            "@@ -1 +1 @@\n-pub fn ordinary() -> bool { false }\n+pub fn ordinary() -> bool { true }\n"
        )
        upgraded = BUILD.prepare_stage(source.root, stage.root, member, owned_patch)
        upstream = tomllib.loads(self.files["codex-rs/Cargo.lock"].decode())["package"]
        kept = tomllib.loads((stage.root / "codex-rs/Cargo.lock").read_text())["package"]
        self.assertEqual([p for p in kept if p["name"] != "cmux-managed-codex-host"], upstream)
        self.assertEqual((stage.root / "LICENSE").read_bytes(), self.files["LICENSE"])
        self.assertEqual((source.root / "codex-rs/app-server/src/in_process.rs").read_bytes(),
                         self.files["codex-rs/app-server/src/in_process.rs"])
        self.assertEqual((stage.root / "codex-rs/cmux-managed-codex-host/src/main.rs").read_text(), "fn main() {}\n")
        self.assertIn("true", (stage.root / "codex-rs/app-server/src/in_process.rs").read_text())
        self.assertEqual(BUILD.prepare_stage(source.root, stage.root, member, owned_patch), upgraded)

    def test_locked_runner_rejects_foreign_target_and_unapproved_commands_before_compiler(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        foreign = self.root / "foreign-target"
        foreign.mkdir()
        sentinel = foreign / "keep"
        sentinel.write_text("untouched")
        rust = self.root / "rust"
        rust.mkdir()
        for name in ("cargo", "rustc", "rustdoc"):
            tool = rust / name
            tool.write_text("#!/bin/sh\nexit 99\n")
            tool.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
        for args in [["clean"], ["run"], ["update"], ["install", "x"],
                     ["test", "-p", "codex-app-server", "--manifest-path", "/foreign"]]:
            with self.subTest(args=args), self.assertRaises(BUILD.BuildError):
                BUILD.run_locked(stage, self.root / "new-target", rust, args)
        with self.assertRaises(BUILD.BuildError):
            BUILD.run_locked(stage, foreign, rust, ["test", "-p", "codex-app-server", "--lib", "cmux_frozen_"])
        self.assertEqual(sentinel.read_text(), "untouched")
        self.assertEqual(list(foreign.iterdir()), [sentinel])

    def test_locked_runner_executes_only_direct_pinned_tools_with_owned_target_and_receipts(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        rust = self.compiler()
        target = self.root / "target"
        args = ["test", "-p", "codex-app-server", "--lib", "cmux_frozen_"]
        with patch.object(BUILD, "_free_bytes", return_value=61 * 1024**3):
            first = BUILD.run_locked(stage, target, rust, args)
            second = BUILD.run_locked(stage, target, rust, args)
        call = json.loads((self.root / "compiler-call.json").read_text())
        self.assertEqual(call["args"], ["test", "--locked", "--jobs", "2", *args[1:]])
        self.assertEqual(call["cwd"], str(stage.root / "codex-rs"))
        self.assertEqual(call["target"], str(target))
        self.assertEqual(call["rustc"], str(rust / "rustc"))
        self.assertEqual(call["incremental"], "0")
        self.assertEqual(call["dev_debug"], "0")
        self.assertEqual(call["test_debug"], "0")
        self.assertNotEqual(first.receipt, second.receipt)
        self.assertTrue(first.log.is_file())
        receipt = json.loads(first.receipt.read_text())
        self.assertEqual(receipt["exit_code"], 0)
        self.assertTrue(receipt["stage_unchanged"])
        self.assertFalse(receipt["qualification"])
        other = BUILD.prepare_stage(source.root, self.root / "other-stage", None, None)
        with patch.object(BUILD, "_free_bytes", return_value=61 * 1024**3), self.assertRaises(BUILD.BuildError):
            BUILD.run_locked(other, target, rust, args)

    def test_runner_refuses_low_capacity_and_wrong_toolchain_without_creating_target(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        rust = self.compiler(version="1.94.0")
        target = self.root / "target"
        args = ["test", "-p", "codex-core", "--lib", "cmux_direct_mode_"]
        with patch.object(BUILD, "_free_bytes", return_value=59 * 1024**3), self.assertRaisesRegex(
            BUILD.BuildError, "60GiB"
        ):
            BUILD.run_locked(stage, target, rust, args)
        self.assertFalse(target.exists())
        with patch.object(BUILD, "_free_bytes", return_value=61 * 1024**3), self.assertRaisesRegex(
            BUILD.BuildError, "1.95.0"
        ):
            BUILD.run_locked(stage, target, rust, args)
        self.assertFalse(target.exists())
        self.assertFalse((self.root / "compiler-call.json").exists())

    def test_runner_does_not_report_success_when_compiler_changes_the_lock(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        rust = self.compiler(change_lock=True)
        target = self.root / "target"
        with patch.object(BUILD, "_free_bytes", return_value=61 * 1024**3), self.assertRaises(BUILD.BuildError):
            BUILD.run_locked(stage, target, rust, ["check", "-p", "codex-app-server"])
        receipts = [path for path in target.glob("*.json") if path.name != BUILD.TARGET_OWNER]
        self.assertEqual(len(receipts), 1)
        self.assertFalse(json.loads(receipts[0].read_text())["stage_unchanged"])
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, stage.root, None, None)

    def test_stage_rejects_unapproved_patch_or_source_alias_before_writes(self):
        source = self.source()
        stage = self.root / "stage"
        bad_patch = self.root / "bad.patch"
        bad_patch.write_text(
            "diff --git a/LICENSE b/LICENSE\n--- a/LICENSE\n+++ b/LICENSE\n"
            "@@ -1 +1 @@\n-fixture license\n+changed\n"
        )
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, stage, None, bad_patch)
        self.assertFalse(stage.exists())
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, source.root / "nested-stage", None, None)
        self.assertFalse((source.root / "nested-stage").exists())

    def test_stage_rejects_corrupted_owner_patch_paths_before_any_write(self):
        source = self.source()
        (self.root / "stages").mkdir()
        stage = BUILD.prepare_stage(source.root, self.root / "stages/stage", None, None)
        source_neighbor = self.root / "outside.rs"
        source_neighbor.write_text("source-side neighboring file")
        stage_neighbor = self.root / "stages/outside.rs"
        stage_neighbor.write_text("keep stage-side neighboring file")
        owner_path = stage.root / BUILD.STAGE_OWNER
        owner = json.loads(owner_path.read_text())
        owner["patch_paths"] = ["../outside.rs"]
        owner_path.write_text(json.dumps(owner))
        with self.assertRaises(BUILD.BuildError):
            BUILD.prepare_stage(source.root, stage.root, None, None)
        self.assertEqual(stage_neighbor.read_text(), "keep stage-side neighboring file")

    def test_stage_rechecks_upstream_pins_even_if_owner_inventory_is_rewritten(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        lock = stage.root / "codex-rs/Cargo.lock"
        lock.write_bytes(lock.read_bytes().replace(b"1.0.0", b"2.0.0"))
        owner_path = stage.root / BUILD.STAGE_OWNER
        owner = json.loads(owner_path.read_text())
        owner["files"] = BUILD._snapshot(stage.root, [BUILD.STAGE_OWNER])
        owner_path.write_text(json.dumps(owner))
        with self.assertRaisesRegex(BUILD.BuildError, "upstream workspace settings or lock"):
            BUILD.prepare_stage(source.root, stage.root, None, None)
        self.assertIn(b"2.0.0", lock.read_bytes())

    def test_traditional_deletion_patch_is_refused_by_the_prewrite_guard(self):
        source = self.source()
        deletion = self.root / "traditional-delete.patch"
        name = "codex-rs/app-server/src/in_process.rs"
        deletion.write_text(
            f"--- a/{name}\n+++ /dev/null\n@@ -1 +0,0 @@\n"
            "-pub fn ordinary() -> bool { false }\n"
        )
        rejected = False
        try:
            BUILD._patch_paths(source.root, deletion)
        except BUILD.BuildError:
            rejected = True
        self.assertTrue(rejected, "The actual pre-write patch guard accepted deletion")
        self.assertEqual((source.root / name).read_bytes(), self.files[name])
        self.assertFalse((self.root / "stage").exists())

    def test_checked_control_patch_path_is_validated_without_widening_neighbors(self):
        source = self.root / "checked-control-source"
        name = "codex-rs/app-server/src/outgoing_message.rs"
        target = source / name
        target.parent.mkdir(parents=True)
        original = b"pub fn ordinary() {}\n"
        target.write_bytes(original)
        integration = self.root / "checked-control.patch"
        integration.write_text(
            f"diff --git a/{name} b/{name}\n"
            f"--- a/{name}\n+++ b/{name}\n@@ -1 +1 @@\n"
            "-pub fn ordinary() {}\n+pub fn checked() {}\n"
        )
        self.assertEqual(BUILD._patch_paths(source, integration), {name})
        self.assertEqual(target.read_bytes(), original)
        neighbor = "codex-rs/app-server/src/outgoing_message_extra.rs"
        (source / neighbor).write_bytes(original)
        rejected = self.root / "neighbor.patch"
        rejected.write_text(integration.read_text().replace(name, neighbor))
        with self.assertRaises(BUILD.BuildError):
            BUILD._patch_paths(source, rejected)
        self.assertEqual((source / neighbor).read_bytes(), original)

    def _assert_checked_listener_patch_path(self, name):
        source = self.root / "checked-listener-source"
        target = source / name
        target.parent.mkdir(parents=True)
        original = b"pub fn ordinary() {}\n"
        target.write_bytes(original)
        integration = self.root / "checked-listener.patch"
        integration.write_text(
            f"diff --git a/{name} b/{name}\n"
            f"--- a/{name}\n+++ b/{name}\n@@ -1 +1 @@\n"
            "-pub fn ordinary() {}\n+pub fn checked() {}\n"
        )
        accepted = None
        try:
            accepted = BUILD._patch_paths(source, integration)
        except BUILD.BuildError:
            pass
        self.assertEqual(accepted, {name}, "Actual pre-write guard rejected the approved listener path")
        self.assertEqual(target.read_bytes(), original)
        neighbor = name.removesuffix(".rs") + "_extra.rs"
        (source / neighbor).write_bytes(original)
        rejected = self.root / "listener-neighbor.patch"
        rejected.write_text(integration.read_text().replace(name, neighbor))
        with self.assertRaises(BUILD.BuildError):
            BUILD._patch_paths(source, rejected)
        mismatch = self.root / "listener-mismatched-headers.patch"
        other = "codex-rs/app-server/src/in_process.rs"
        mismatch.write_text(integration.read_text().replace(f"+++ b/{name}", f"+++ b/{other}"))
        with self.assertRaises(BUILD.BuildError):
            BUILD._patch_paths(source, mismatch)
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual((source / neighbor).read_bytes(), original)

    def test_checked_message_processor_listener_patch_path_is_exact(self):
        self._assert_checked_listener_patch_path("codex-rs/app-server/src/message_processor.rs")

    def test_checked_thread_processor_listener_patch_path_is_exact(self):
        self._assert_checked_listener_patch_path(
            "codex-rs/app-server/src/request_processors/thread_processor.rs"
        )

    def test_sdk_patch_allowlist_is_exactly_the_eight_reviewed_sources(self):
        self.assertEqual(BUILD.PATCH_PATHS, frozenset({
            "codex-rs/app-server/src/config_manager.rs",
            "codex-rs/app-server/src/config_manager_service.rs",
            "codex-rs/app-server/src/in_process.rs",
            "codex-rs/app-server/src/outgoing_message.rs",
            "codex-rs/app-server/src/message_processor.rs",
            "codex-rs/app-server/src/request_processors/thread_processor.rs",
            "codex-rs/core/src/tools/mod.rs",
            "codex-rs/core/src/lib.rs",
        }))

    def test_full_owned_helper_suite_is_allowed_but_upstream_suites_stay_bounded(self):
        accepted = None
        try:
            accepted = BUILD._cargo_args(["test", "-p", BUILD.MEMBER])
        except BUILD.BuildError:
            pass
        self.assertEqual(accepted, BUILD.MEMBER, "The actual runner rejects the required complete owned suite")
        with self.assertRaises(BUILD.BuildError):
            BUILD._cargo_args(["test", "-p", "codex-app-server", "--lib"])

    def test_locked_runner_passes_the_complete_owned_suite_without_a_name_filter(self):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", self.member(), None)
        rust = self.compiler()
        with patch.object(BUILD, "_free_bytes", return_value=61 * 1024**3):
            result = BUILD.run_locked(stage, self.root / "target", rust, ["test", "-p", BUILD.MEMBER])
        call = json.loads((self.root / "compiler-call.json").read_text())
        self.assertEqual(call["args"], ["test", "--locked", "--jobs", "2", "-p", BUILD.MEMBER])
        self.assertEqual(json.loads(result.receipt.read_text())["exit_code"], 0)

    def watchdog(self, *, uncertain):
        source = self.source()
        stage = BUILD.prepare_stage(source.root, self.root / "stage", None, None)
        rust = self.compiler()
        target = self.root / "target"
        process = Mock(pid=424242)
        process.poll.return_value = None
        timeout = subprocess.TimeoutExpired("controlled compiler", 30)
        process.wait.side_effect = timeout if uncertain else [timeout, timeout, -signal.SIGKILL, -signal.SIGKILL]

        def version(command, **_):
            return subprocess.CompletedProcess(command, 0, f"{Path(command[0]).name} 1.95.0 (fixture)\n", "")

        def group_signal(_, value):
            if value == 0 and not uncertain:
                raise ProcessLookupError

        with patch.object(BUILD.subprocess, "run", side_effect=version), \
             patch.object(BUILD.subprocess, "Popen", return_value=process), \
             patch.object(BUILD, "_free_bytes", side_effect=[61 * 1024**3, 49 * 1024**3]), \
             patch.object(BUILD.os, "getpgid", return_value=process.pid), \
             patch.object(BUILD.os, "killpg", side_effect=group_signal) as signals:
            observed = None
            try:
                BUILD.run_locked(stage, target, rust, ["check", "-p", "codex-app-server"])
            except (BUILD.BuildError, subprocess.TimeoutExpired) as error:
                observed = error
        self.assertIsNotNone(observed)
        self.assertIn(signal.SIGKILL, [call.args[1] for call in signals.call_args_list],
                      "Watchdog abandoned its verified group after the second grace period")
        receipts = [path for path in target.glob("*.json") if path.name != BUILD.TARGET_OWNER]
        self.assertEqual(len(receipts), 1, "Every watchdog failure must retain its receipt")
        return observed, json.loads(receipts[0].read_text())

    def test_watchdog_escalates_to_kill_and_records_failure_after_both_grace_periods(self):
        error, receipt = self.watchdog(uncertain=False)
        self.assertIsInstance(error, BUILD.BuildError)
        self.assertEqual(receipt["failure"], "shared_volume_reserve")
        self.assertTrue(receipt["cleanup"]["confirmed"])
        self.assertFalse(receipt["cleanup"]["live_work_uncertain"])
        self.assertEqual(receipt["exit_code"], -signal.SIGKILL)

    def test_watchdog_records_explicit_live_work_uncertainty_if_final_escalation_is_unverified(self):
        error, receipt = self.watchdog(uncertain=True)
        self.assertIsInstance(error, BUILD.BuildError)
        self.assertIn("live work", str(error))
        self.assertFalse(receipt["cleanup"]["confirmed"])
        self.assertTrue(receipt["cleanup"]["live_work_uncertain"])
        self.assertEqual(receipt["cleanup"]["pid"], 424242)
        self.assertIsNone(receipt["exit_code"])

    def test_watchdog_never_signals_a_changed_group_and_reports_uncertainty(self):
        process = Mock(pid=424242)
        process.poll.return_value = None
        with patch.object(BUILD.os, "getpgid", return_value=654321), \
             patch.object(BUILD.os, "killpg") as signals:
            status, cleanup = BUILD._stop_owned_compiler(process)
        self.assertIsNone(status)
        self.assertTrue(all(call.args[1] == 0 for call in signals.call_args_list))
        self.assertEqual(cleanup["signals"], [])
        self.assertFalse(cleanup["confirmed"])
        self.assertTrue(cleanup["live_work_uncertain"])

    def test_cli_requires_an_explicit_side_effect_mode(self):
        result = subprocess.run([sys.executable, str(SPEC.origin)], capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("required", result.stderr)


if __name__ == "__main__":
    unittest.main()
