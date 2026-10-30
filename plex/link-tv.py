#!/usr/bin/env python3
"""Build a Plex-parseable symlink tree for the read-only APFS show library."""

import re
import pathlib

HOST_SRC = pathlib.Path("/mnt/media/root/plexmedia/shows")  # where we read names
CTR_SRC = "/media/shows"  # what the symlink points at
OUT = pathlib.Path("/home/itdojo/docker/plex/tv")

# Season each show's files belong to. The Office files are season 2, not season 1.
SEASON = {"Firefly": 1, "Stranger Things": 1, "The Office": 2}

# Firefly's leading numbers are production order and collide (two 09, no 11),
# so that show is mapped by title to TVDB aired order instead.
FIREFLY = {
    "Serenity": 1,
    "The Train Job": 2,
    "Bushwhacked": 3,
    "Shindig": 4,
    "Safe": 5,
    "Our Mrs. Reynolds": 6,
    "Jaynestown": 7,
    "Out of Gas": 8,
    "Ariel": 9,
    "War Stories": 10,
    "Trash": 11,
    "The Message": 12,
    "Heart of Gold": 13,
    "Objects in Space": 14,
}


def title_of(stem):
    t = re.sub(r"^\d+\s+", "", stem)  # drop leading episode number
    t = re.sub(r"\s*\(1080p HD\)$", "", t)  # drop the quality tag
    t = re.sub(r"\s+1$", "", t)  # drop the " 1" copy-dedup suffix
    return t.replace("_", " -").strip()


made, skipped = [], []
for show_dir in sorted(p for p in HOST_SRC.iterdir() if p.is_dir()):
    show = show_dir.name
    season = SEASON[show]
    seen = {}
    for f in sorted(show_dir.iterdir()):
        if f.suffix.lower() != ".m4v":
            continue
        title = title_of(f.stem)
        if show == "Firefly":
            ep = FIREFLY[title]
        else:
            ep = int(re.match(r"^(\d+)", f.stem).group(1))
        if ep in seen:  # duplicate file for one episode
            skipped.append(f"{show} e{ep:02d}: {f.name} (dupe of {seen[ep]})")
            continue
        seen[ep] = f.name
        dest_dir = OUT / show / f"Season {season:02d}"
        dest_dir.mkdir(parents=True, exist_ok=True)
        safe = title.replace("/", "-")
        link = dest_dir / f"{show} - s{season:02d}e{ep:02d} - {safe}{f.suffix}"
        if link.is_symlink() or link.exists():
            link.unlink()
        link.symlink_to(f"{CTR_SRC}/{show}/{f.name}")
        made.append(str(link.relative_to(OUT)))

print(f"linked {len(made)}")
for m in made:
    print("  " + m)
if skipped:
    print(f"skipped {len(skipped)}")
    for s in skipped:
        print("  " + s)
