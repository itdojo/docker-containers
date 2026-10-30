# Working notes — docker-containers

Append immediately when something below happens; do not batch. Read this file at the start of every session and again after any compaction, before proposing an approach. Keep entries to 1–3 lines. This is not a narrative log of work performed — that is what git history is for.

Stack-level working notes live beside their stack (`frigate/docs/`, `mediamtx/docs/`, `ntopng/docs/`). This file is for the library as a whole.

## Constraints

- Repo is **public** as of 2026-08-21 (`policy: notify` in the fleet manifest), reversing 2026-08-16's move to private. A pushed stack is published, so nothing tracked names a private path; the `no-private-paths` hook refuses one.
- `*.mp4` is ignored at the root. Large media does not enter history — it cannot be removed later without a rewrite.
- `https-right-quick/.env` is tracked on purpose. Its re-include must stay in `https-right-quick/.gitignore`; a root-level negation cannot override a nested `.gitignore`.

## Decisions

- 2026-10-24 — `geofence-draw` opens on a world view (`[20, 0]`, zoom 2) and uses the Eiffel Tower as its typed example, not a real local area, so opening it on a projector shows nobody's location (embedded-systems-2026 ch18). Its panel text (`GEOFENCE_FILE`, `.env` corners, Labs 11 and 12) stays, because halow-lora-2026 Lab 11a documents it.
- 2026-09-24 — `plex` media drive mounted by kernel exFAT via `/etc/fstab` (`plex/host/media.fstab`), read-only, `x-systemd.before=docker.service`. Supersedes the `apfs-fuse` service below. Read-only kept by choice: Plex never writes media, and exFAT has no journal to survive a yanked cable.
- 2026-09-24 — UAS disabled for the Seagate (`usb-storage.quirks=0bc2:231a:u` in `cmdline.txt`) rather than a powered hub. Under UAS it dropped off the bus 38 s into a read; on `usb-storage` a full tree walk plus 6 GB read and a Plex scan ran clean. Backups: `cmdline.txt.bak-2026-09-24`, `fstab.bak-2026-09-24`.
- 2026-09-24 — `MEDIA_PATH=/mnt/media/plexmedia` so the stack fails closed: without the drive the bind source does not exist and the container does not start. `/mnt/media` must stay empty on the SD card.
- 2026-08-21 — Public again, reversing 2026-08-16's move to private for the host-preparing stacks. The vault's `docker-containers-returns-to-public` decision carries why.
- 2026-08-16 — Local folder `kismet-repo-gpsd` renamed to `kismet-gpsd-repo` to match the remote and its `kismet-gpsd-source` sibling. The local name was a transposition.
- 2026-09-17 (superseded 2026-09-24) — `plex` mounts its APFS media drive read-only via `apfs-fuse` rather than reformatting to ext4. The drive held a populated 4 TB library; Plex never writes into a media tree, so read-only costs nothing and the data survived.
- 2026-09-17 — `plex` pre-roll left unset. All 105 clips are zero bytes; pointing `CinemaTrailersPrerollID` at them breaks playback instead of decorating it.
- 2026-09-17 (superseded 2026-09-24) — The APFS mount is a forking systemd *service*, not a `.mount` unit. A `.mount` unit needs a `/sbin/mount.fuse.apfs-fuse` helper that `apfs-fuse` does not install. `Before=docker.service` is load-bearing: Plex starting against an empty `/mnt/media` marks the whole library missing.
- 2026-08-16 — `excalidraw` allowed to keep `build:` against upstream. Its Dockerfile clones upstream *inside* the image, so the tree stays two files; the rule that matters is "no third-party source on disk", not "no `build:`".

## Ruled out

- Force-replacing the remote with the local tree. The remote held 7 stacks the local tree never had; merging kept all 14.
- Setting the Plex server name via the official image's `PLEX_PREFERENCE_1=FriendlyName=...`. It does not apply — not on first start, not on a restart against a populated config. Set it with a `PUT /:/prefs` against the running server instead.
- Reformatting the `plex` media drive to ext4. Native and faster, but it wipes a populated 4 TB library.
- Git LFS for the ntopng explainer videos. Would put an LFS dependency on every machine fleet bootstraps.

## Gotchas

- **2026-09-24: the `plex` media drive is now exFAT, not APFS.** `/dev/sda2` was reformatted on a Mac (label `plex_4tb`, UUID `6AAC-8DD4`) and holds only `plexmedia/movies/`. `apfs-media.service` has failed since 2026-09-17 19:36 (`invalid superblock`), so Plex has read an empty SD-card directory ever since. The APFS gotchas below are historical.
- `dojoplex` is a **Raspberry Pi 4 Model B**, not a Pi 5 as `plex/README.md` says. Pi 4 shares 1.2 A across all USB ports.
- **The local tree was never a clone.** Between 2026-07-27 and 2026-08-16 the repo was pushed once, then the local `.git` vanished and four new stacks were built on top of an untracked directory. If `git status` ever shows the entire repo as untracked again, do not `git init` — reattach the real history.
- `pihole-dnscrypt/etc-pihole/` is a live bind-mount, not a template. It accumulates a generated admin password hash (`pihole.toml`) and a `tls.pem` private key. Ignored since 2026-08-16; it was never committed.
- **261 of 717 files on the `plex` media drive are zero bytes** — all 40 episodes in `shows/`, all 105 `preroll/` clips, and two movies. Not an `apfs-fuse` fault: the same mount reads 25–38 GB movie files fine, and the empty files carry no `com.apple.decmpfs` attribute. The data was never copied to the disk. Check file sizes before blaming a FUSE driver.
- Plex's TV scanner cannot parse `01 Serenity (1080p HD).m4v` — no season, no `SxxExx`. With read-only media the fix is a symlink tree on writable storage (`plex/link-tv.py` → `./tv`), pointed at by the library. Symlinks target container paths, so they read as broken from the host; that is correct.
- **`apfs-fuse` exposes the volume's internal layout, so the filesystem root is one level down.** The `plex` library is at `/mnt/media/root/plexmedia`, not `/mnt/media/plexmedia`. `df` also reports the volume 100% full — it reports APFS container capacity consumed, not free space. Both are cosmetic read-only; both will waste your time once.
- `apfs-fuse` must be cloned `--recursive`; the lzfse decompressor is a submodule and the build fails without it.
- `hostapd/config/hostapd.conf` is safe to read — `wpa_passphrase=$WPA_PASSPHRASE` is an envsubst placeholder. The real value is in the ignored `.env`.
