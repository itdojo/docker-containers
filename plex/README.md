# plex

Plex Media Server on `dojoplex`, a Raspberry Pi 4 Model B running Debian trixie (aarch64). The media lives on a 4 TB Seagate Expansion USB drive, formatted **exFAT** on a Mac, so the stack is two pieces: a read-only kernel mount of the drive and a container that reads it.

## The drive

`/dev/sda2` is an exFAT volume labelled `plex_4tb` (UUID `6AAC-8DD4`) carrying `plexmedia/movies/`. The kernel's own exFAT driver mounts it; nothing needs building. `host/media.fstab` is the line that goes in `/etc/fstab`:

```bash
sudo mkdir -p /mnt/media
cat host/media.fstab | sudo tee -a /etc/fstab
sudo systemctl daemon-reload && sudo mount /mnt/media
```

The mount is **read-only** even though exFAT can be written. Plex reads media and writes nothing back into the library; everything it generates — the database, metadata, artwork, transcode scratch — lands in `./config`, on the SD card. Read-only also means a yanked cable cannot leave the volume dirty, which matters on a filesystem with no journal.

`uid=1000,gid=1000` hands every file to the Plex user, since exFAT has no ownership of its own. `nofail` keeps the Pi booting without the drive. `x-systemd.before=docker.service` orders the mount ahead of Docker, because a `nofail` mount is otherwise not ordered before anything.

If the drive is missing anyway, the stack fails closed: `MEDIA_PATH` is `/mnt/media/plexmedia`, which exists only when the drive is mounted, so the bind fails and the container does not start. Keep `/mnt/media` itself empty on the SD card. A stray `plexmedia` directory there would let Plex start against nothing and mark the whole library missing.

### UAS is disabled for this drive

Over UAS, the Seagate (`0bc2:231a`) drops off the bus within a minute of sustained reads — `usb 2-2: USB disconnect`, then `Device offlined - not ready after error recovery`. Forcing it onto plain `usb-storage` fixes that. The quirk is the first token of `/boot/firmware/cmdline.txt` and takes effect on reboot:

```
usb-storage.quirks=0bc2:231a:u
```

`dmesg | grep "UAS is ignored"` confirms it applied. The throughput cost does not matter for a spinning disk serving direct play.

## The container

```bash
cp .env.example .env    # then edit
docker compose up -d
```

`network_mode: host`, which is the usual arrangement for a dedicated Plex box: GDM discovery, DLNA and remote access all work without publishing anything by hand. The server answers on `:32400`, web UI at `http://dojoplex:32400/web`.

A `PLEX_CLAIM` token from [plex.tv/claim](https://plex.tv/claim) binds the server to your account on first start. It is valid for four minutes and used once — after that the server is claimed for good and the value in `.env` is inert. Leave it empty and you claim through the web UI instead.

Nothing here passes `/dev/dri` through. The Pi's video engine is not something Plex can drive, so transcoding is CPU-only and slow; this box is for direct play. If a client is transcoding, the fix is the client's settings or the file, not the host.

## Setting the server name

The official image documents `PLEX_PREFERENCE_*` env vars for seeding preferences, but `FriendlyName` did not take through that path on this image — not on first start, not on a restart with the config already populated. Set it directly against the running server instead:

```bash
PREFS="config/Library/Application Support/Plex Media Server/Preferences.xml"
TOKEN=$(grep -o 'PlexOnlineToken="[^"]*"' "$PREFS" | cut -d'"' -f2)
curl -X PUT "http://localhost:32400/:/prefs?FriendlyName=dojoPlex&X-Plex-Token=$TOKEN"
```

It persists in `Preferences.xml`, so this is a once-per-server step, not something to automate.

## What is actually on the drive

Only `movies/` — 412 folders, 1,248 files, none of them zero bytes, and `Movies` scans to 408 items. There is no `shows/` or `preroll/` on this volume, so `TV Shows` is empty and the pre-roll preference stays unset.

## The TV symlink tree

The drive currently carries no episodes, so this tree is dormant — its symlinks point at `/media/shows/`, which does not exist. It is kept for when the shows come back. The episode filenames cannot be parsed by Plex's TV scanner. They look like `01 Serenity (1080p HD).m4v` — a leading number, no season, no `SxxExx`. The drive is read-only, so renaming in place is not available.

`link-tv.py` builds a parseable tree of symlinks on the SD card at `./tv`, mounted into the container at `/tv`, which is where the `TV Shows` library points. The symlinks target *container* paths (`/media/shows/...`), so they resolve inside Plex and read as broken from the host. That is expected.

Three things the script encodes that a generic scanner cannot work out:

- **The Office files are season 2**, not season 1. `The Dundies` through `Casino Night` is S02E01–E22; the numbering matches season 2 exactly. E19 *Michael's Birthday* is absent.
- **Firefly's numbers are production order**, and they collide — two `09`s, no `11`. The script maps that show by title to TVDB aired order instead.
- One duplicate (`01 The Dundies 1.m4v`) is skipped.

Rerun it after adding episodes:

```bash
./link-tv.py    # rewrites ./tv from scratch; edit SEASON/FIREFLY tables for new shows
```

## Layout

| Path | What it is |
| --- | --- |
| `compose.yaml` | The stack. One service, host networking. |
| `.env.example` | Copy to `.env`. Holds the claim token, media path, UID/GID, TZ. |
| `host/media.fstab` | The `/etc/fstab` line that mounts `/dev/sda2` read-only at `/mnt/media`. |
| `link-tv.py` | Builds the `./tv` symlink tree that makes the episode files scannable. |
| `config/` | Runtime state — Plex's database, metadata and artwork. Not committed. |
| `tv/` | Generated symlinks. Not committed — rebuild with `link-tv.py`. |

Inside the container the media is at `/media`, read-only. The `Movies` library points at `/media/movies`; `TV Shows` points at `/tv`, the symlink tree, not at `/media/shows`.
