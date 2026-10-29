#!/usr/bin/env python3
"""Exercise actual extraction of untrusted tar headers, without cloud services."""
import io
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[1] / "scripts/restore-archive.py"


def entry(name, kind=tarfile.REGTYPE, mode=0o644, link=""):
    item = tarfile.TarInfo(name)
    item.type, item.mode, item.linkname = kind, mode, link
    item.uid = item.gid = 0
    item.size = 4 if kind == tarfile.REGTYPE else 0
    return item


class RestoreTests(unittest.TestCase):
    def restore(self, entries, target):
        data = io.BytesIO()
        with tarfile.open(fileobj=data, mode="w") as archive:
            for item in entries:
                archive.addfile(item, io.BytesIO(b"data") if item.isfile() else None)
        return subprocess.run([sys.executable, str(HELPER), str(target)],
                              input=data.getvalue(), capture_output=True)

    def test_data_links_and_ownership(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.restore([entry("dir/file"), entry("link", tarfile.SYMTYPE, link="dir/file"),
                                   entry("hard", tarfile.LNKTYPE, link="dir/file")], root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "link").read_bytes(), b"data")
            self.assertEqual((root / "hard").stat().st_ino, (root / "dir/file").stat().st_ino)
            self.assertEqual((root / "dir/file").stat().st_uid, os.geteuid())
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)

    def test_privileged_entries_rejected(self):
        for item in [entry("bad", mode=0o4755), entry("bad", mode=0o2755),
                     entry("bad", tarfile.CHRTYPE), entry("bad", tarfile.BLKTYPE),
                     entry("bad", tarfile.FIFOTYPE)]:
            with self.subTest(kind=item.type, mode=item.mode), tempfile.TemporaryDirectory() as tmp:
                result = self.restore([item], tmp)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(list(Path(tmp).iterdir()), [])

    def test_traversal_and_links_rejected(self):
        for items in [[entry("../escape")],
                      [entry("bad", tarfile.SYMTYPE, link="../escape")],
                      [entry("bad", tarfile.LNKTYPE, link="/etc/passwd")],
                      [entry("dir", tarfile.SYMTYPE, link="../escape"), entry("dir/file")],
                      [entry("file"), entry("file")]]:
            with self.subTest(items=items), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / "target"
                root.mkdir()
                self.assertNotEqual(self.restore(items, root).returncode, 0)
                self.assertFalse((Path(tmp) / "escape").exists())

    def test_symlink_target_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "real").mkdir()
            (root / "alias").symlink_to(root / "real")
            self.assertNotEqual(self.restore([entry("file")], root / "alias").returncode, 0)
            self.assertEqual(list((root / "real").iterdir()), [])

    def test_symlink_parent_traversal_is_not_lexically_normalized(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target"
            target.mkdir()
            (root / "outside").write_text("external secret")
            result = self.restore([entry("outside"),
                                   entry("alias", tarfile.SYMTYPE, link="."),
                                   entry("escape", tarfile.SYMTYPE, link="alias/../outside")], target)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((target / "escape").is_symlink())

    def test_contained_parent_relative_link(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            result = self.restore([entry("file"),
                                   entry("sub/link", tarfile.SYMTYPE, link="../file")], root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "sub/link").read_bytes(), b"data")

    def test_safe_directory_modes_inside_private_staging(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "target"
            root.mkdir()
            parent_mode = Path(tmp).stat().st_mode
            result = self.restore([entry(".", tarfile.DIRTYPE, mode=0o777),
                                   entry("shared", tarfile.DIRTYPE, mode=0o775),
                                   entry("shared/file"),
                                   entry("private", tarfile.DIRTYPE, mode=0o700)], root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root / "shared").stat().st_mode & 0o777, 0o755)
            self.assertEqual((root / "private").stat().st_mode & 0o777, 0o700)
            self.assertEqual(root.stat().st_mode & 0o777, 0o700)
            self.assertEqual(Path(tmp).stat().st_mode, parent_mode)


if __name__ == "__main__":
    unittest.main()
