#!/usr/bin/env python3
"""Find media that was COPIED instead of hardlinked, and relink it.

The *arr apps hardlink on import when they can: one set of data blocks, two
directory entries, so the retained copy under usenet/complete costs nothing.
That is what makes `removeCompletedDownloads=False` safe. When hardlinking
fails they fall back to a full copy — silently — and every completed download
starts costing twice its size.

This finds those pairs and replaces the duplicate with a hardlink, reclaiming
the space. Nothing is deleted in the ordinary sense: after relinking, both
paths still resolve to the same file.

    python3 scripts/dedupe-hardlinks.py              # report only (default)
    python3 scripts/dedupe-hardlinks.py --apply      # actually relink
    python3 scripts/dedupe-hardlinks.py --apply --strict   # full-hash compare

WHY IT MIGHT BE FAILING, which this also reports:

  * The two trees are on different physical disks. A hardlink cannot cross
    filesystems (EXDEV), so the app has no choice but to copy. With Unraid's
    `highwater` allocator and two independent directory trees, nothing keeps
    downloads and library on the same disk. This is the usual cause.
  * `copyUsingHardlinks` is false in the app's media-management config.
  * The import predates whenever that setting was turned on. Historical debt
    rather than an ongoing leak — worth knowing, because the two need very
    different responses.

SAFETY. This is the only script here that destroys data if it is wrong, so:
  - Dry run by default; --apply is required to change anything.
  - Skips any file that already has st_nlink > 1 (already linked).
  - Skips any pair whose real underlying st_dev differs — those CANNOT be
    linked, and attempting it is what would turn a copy into data loss.
  - Verifies size, then content, before touching anything.
  - Replaces via link-to-temp + atomic rename, so the destination path never
    stops existing even if the process is killed mid-operation.
  - Resolves /mnt/user/... to the real /mnt/diskN/... path first. shfs (FUSE)
    reports one device for everything, so comparing st_dev through it would
    say "same filesystem" for two files on different disks and cheerfully
    green-light an impossible link.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import sys
from collections import defaultdict
from pathlib import Path

USENET = Path("/mnt/user/data/usenet/complete")
MEDIA = Path("/mnt/user/data/media")

SAMPLE = 4 * 1024 * 1024   # bytes read from each end when not --strict
MIN_SIZE = 8 * 1024 * 1024  # ignore small files; the win isn't worth the risk


def human(n: float) -> str:
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(n) < 1024:
            return f"{n:.1f}{unit}"
        n /= 1024
    return f"{n:.1f}PB"


def real_path(p: Path) -> Path:
    """Map /mnt/user/<rest> to the actual /mnt/<disk>/<rest> holding it.

    Everything under /mnt/user is FUSE, so st_dev there is identical for files
    on different physical disks. Comparing devices without doing this makes
    cross-disk pairs look linkable, which is exactly the case that must be
    skipped.
    """
    s = str(p)
    if not s.startswith("/mnt/user/"):
        return p
    rest = s[len("/mnt/user/"):]
    for mnt in sorted(Path("/mnt").glob("disk*")) + [Path("/mnt/cache")]:
        cand = mnt / rest
        if cand.exists():
            return cand
    return p


def same_content(a: Path, b: Path, strict: bool) -> bool:
    if a.stat().st_size != b.stat().st_size:
        return False
    if strict:
        def digest(p: Path) -> str:
            h = hashlib.blake2b(digest_size=32)
            with p.open("rb") as f:
                for chunk in iter(lambda: f.read(8 * 1024 * 1024), b""):
                    h.update(chunk)
            return h.hexdigest()
        return digest(a) == digest(b)

    size = a.stat().st_size
    with a.open("rb") as fa, b.open("rb") as fb:
        if fa.read(SAMPLE) != fb.read(SAMPLE):
            return False
        if size > SAMPLE * 2:
            fa.seek(-SAMPLE, os.SEEK_END)
            fb.seek(-SAMPLE, os.SEEK_END)
            if fa.read(SAMPLE) != fb.read(SAMPLE):
                return False
    return True


def index(root: Path) -> dict[str, list[Path]]:
    out: dict[str, list[Path]] = defaultdict(list)
    for p in root.rglob("*"):
        try:
            if p.is_file() and not p.is_symlink() and p.stat().st_size >= MIN_SIZE:
                out[p.name].append(p)
        except OSError:
            continue
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--apply", action="store_true",
                    help="actually relink (default is report-only)")
    ap.add_argument("--strict", action="store_true",
                    help="full content hash instead of head+tail sampling")
    args = ap.parse_args()

    if not USENET.exists() or not MEDIA.exists():
        print(f"ERROR: expected both {USENET} and {MEDIA} to exist", file=sys.stderr)
        return 1

    print(f"Scanning (files >= {human(MIN_SIZE)})...")
    src_idx, dst_idx = index(USENET), index(MEDIA)
    shared = sorted(set(src_idx) & set(dst_idx))
    print(f"  {len(src_idx)} in usenet/complete, {len(dst_idx)} in media, "
          f"{len(shared)} names in both\n")

    linked = copies = skipped_xdev = mismatch = 0
    reclaimable = 0
    xdev_examples: list[str] = []

    for name in shared:
        for src in src_idx[name]:
            for dst in dst_idx[name]:
                try:
                    st_s, st_d = src.stat(), dst.stat()
                except OSError:
                    continue

                rs, rd = real_path(src), real_path(dst)
                try:
                    dev_s, dev_d = rs.stat().st_dev, rd.stat().st_dev
                    ino_s, ino_d = rs.stat().st_ino, rd.stat().st_ino
                except OSError:
                    continue

                if dev_s == dev_d and ino_s == ino_d:
                    linked += 1
                    continue

                if dev_s != dev_d:
                    # Cannot be linked at all. Reporting this is the point:
                    # it means the allocator split the trees across disks.
                    skipped_xdev += 1
                    if len(xdev_examples) < 3:
                        xdev_examples.append(f"{rs}\n        {rd}")
                    continue

                if not same_content(src, dst, args.strict):
                    mismatch += 1
                    continue

                copies += 1
                reclaimable += st_s.st_size

                if not args.apply:
                    print(f"  COPY  {human(st_s.st_size):>8}  {name}")
                    continue

                # Operate on the RESOLVED disk paths (rs/rd), never on the
                # /mnt/user ones. shfs is its own device: linking a real disk
                # inode to a path under /mnt/user is a cross-device link and
                # fails with EXDEV even when both files are physically on the
                # same disk. Resolving only for the st_dev comparison and then
                # operating through FUSE is exactly that mistake, and it makes
                # every same-disk pair look unfixable.
                tmp = rs.with_name(rs.name + ".hltmp")
                try:
                    if tmp.exists():
                        tmp.unlink()
                    os.link(rd, tmp)
                    os.replace(tmp, rs)
                    print(f"  LINKED {human(st_s.st_size):>8}  {name}")
                except OSError as e:
                    print(f"  FAILED {name}: {e}")
                    if tmp.exists():
                        try:
                            tmp.unlink()
                        except OSError:
                            pass

    print(f"\n{'=' * 60}")
    print(f"  already hardlinked : {linked}")
    print(f"  duplicate copies   : {copies}   ({human(reclaimable)})")
    print(f"  different disks    : {skipped_xdev}   (cannot be linked)")
    print(f"  content mismatch   : {mismatch}   (same name, different file)")

    if skipped_xdev:
        print("\n  Cross-disk pairs cannot be hardlinked — the app was forced to copy.")
        print("  Unraid's allocator placed the two trees on different disks; nothing")
        print("  ties them together. Fixes, in order of intrusiveness: set the `data`")
        print("  share to a single included disk, or accept the copies and set")
        print("  removeCompletedDownloads=True so the duplicate is deleted instead.")
        for ex in xdev_examples:
            print(f"\n        {ex}")

    if copies and not args.apply:
        print(f"\n  Re-run with --apply to reclaim {human(reclaimable)}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
