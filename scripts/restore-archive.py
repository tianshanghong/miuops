#!/usr/bin/env python3
"""Extract a backup stream as data, never as host ownership or special files.

Links are created only after ordinary files, and may refer only to existing
non-link entries inside the target. Archive ownership is deliberately ignored.
The caller checks every pipeline status and wipes the target on failure.
"""
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile


def relative(name):
    parts = PurePosixPath(name.lstrip("/")).parts
    if ".." in parts:
        raise ValueError("parent traversal in archive")
    return Path(*parts)


def extract(stream, target):
    target = Path(target)
    if target.is_symlink() or not target.is_dir() or any(target.iterdir()):
        raise ValueError("target must be an empty real directory")
    if target.stat().st_uid != os.geteuid():
        raise ValueError("target must belong to the restoring user")
    target = target.resolve()
    os.chmod(target, 0o700)
    links = []
    seen = set()
    directories = {}
    # Do not call tarfile.extract: create only explicitly allowed entry types.
    with tarfile.open(fileobj=stream, mode="r|*") as archive:
        for member in archive:
            name = relative(member.name)
            dest = target / name
            if member.mode & 0o6000:
                raise ValueError("setuid/setgid metadata in archive")
            if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
                raise ValueError("special file in archive")
            if name in seen and not member.isdir():
                raise ValueError("duplicate archive member")
            seen.add(name)
            dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if dest != target:
                for parent in dest.parents:
                    if parent == target:
                        break
                    directories.setdefault(parent, 0o755)
            if member.isdir():
                dest.mkdir(exist_ok=True, mode=0o700)
                if dest != target:
                    # Retain owner traversal so a failed upstream stage can wipe
                    # partial output, even if the archive records mode 000.
                    directories[dest] = 0o700 | (member.mode & 0o055)
            elif member.isfile():
                with archive.extractfile(member) as source, dest.open("xb") as output:
                    shutil.copyfileobj(source, output)
                # No owner/group restoration, world writes, set-ID bits or xattrs.
                os.chmod(dest, member.mode & 0o755)
                os.utime(dest, (member.mtime, member.mtime))
            else:
                links.append((dest, member))
    for dest, member in links:
        if os.path.isabs(member.linkname):
            raise ValueError("absolute archive link")
        base = dest.parent if member.issym() else target
        # Preserve '..' while checking components: lexical normalization can hide
        # an earlier symlink (alias/../file does not mean the same thing on disk).
        link_target = base / member.linkname
        if not link_target.resolve(strict=True).is_relative_to(target):
            raise ValueError("archive link escapes target")
        # No chains or links through symlink directories, including earlier links.
        current = link_target
        while current != target:
            if current.is_symlink():
                raise ValueError("archive link traverses another link")
            current = current.parent
        if not link_target.exists():
            raise ValueError("archive link has no existing target")
        if member.issym():
            dest.symlink_to(member.linkname)
        elif link_target.is_file():
            os.link(link_target, dest)
        else:
            raise ValueError("hardlink target is not a regular file")
    # Keep staging private while retaining safe access modes within the volume.
    for directory in sorted(directories, key=lambda path: len(path.parts), reverse=True):
        os.chmod(directory, directories[directory])
    # Consume the complete pipeline, including trailing authenticated age chunks.
    while stream.read(1024 * 1024):
        pass


if __name__ == "__main__":
    try:
        extract(sys.stdin.buffer, sys.argv[1])
    except (OSError, ValueError, tarfile.TarError) as exc:
        print(f"Unsafe or invalid backup: {exc}", file=sys.stderr)
        sys.exit(1)
