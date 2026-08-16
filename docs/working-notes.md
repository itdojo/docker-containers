# Working notes — docker-containers

Append immediately when something below happens; do not batch. Read this file at the start of every session and again after any compaction, before proposing an approach. Keep entries to 1–3 lines. This is not a narrative log of work performed — that is what git history is for.

Stack-level working notes live beside their stack (`frigate/docs/`, `mediamtx/docs/`, `ntopng/docs/`). This file is for the library as a whole.

## Constraints

- Repo is **private** as of 2026-08-16 (`policy: auto` in the fleet manifest). Committing a stack no longer publishes it; publishing is a separate deliberate act.
- `*.mp4` is ignored at the root. Large media does not enter history — it cannot be removed later without a rewrite.
- `https-right-quick/.env` is tracked on purpose. Its re-include must stay in `https-right-quick/.gitignore`; a root-level negation cannot override a nested `.gitignore`.

## Decisions

- 2026-08-16 — Went private rather than staying public. The four stacks added since July (`ntopng`, `frigate`, `hostapd`, `pihole-dnscrypt`) prepare real hosts and carry real network topology; that is bench infrastructure, not classroom material. Reverses the public/`notify` choice recorded 2026-07-16.
- 2026-08-16 — Local folder `kismet-repo-gpsd` renamed to `kismet-gpsd-repo` to match the remote and its `kismet-gpsd-source` sibling. The local name was a transposition.
- 2026-08-16 — `excalidraw` allowed to keep `build:` against upstream. Its Dockerfile clones upstream *inside* the image, so the tree stays two files; the rule that matters is "no third-party source on disk", not "no `build:`".

## Ruled out

- Force-replacing the remote with the local tree. The remote held 7 stacks the local tree never had; merging kept all 14.
- Git LFS for the ntopng explainer videos. Would put an LFS dependency on every machine fleet bootstraps.

## Gotchas

- **The local tree was never a clone.** Between 2026-07-27 and 2026-08-16 the repo was pushed once, then the local `.git` vanished and four new stacks were built on top of an untracked directory. If `git status` ever shows the entire repo as untracked again, do not `git init` — reattach the real history.
- `pihole-dnscrypt/etc-pihole/` is a live bind-mount, not a template. It accumulates a generated admin password hash (`pihole.toml`) and a `tls.pem` private key. Ignored since 2026-08-16; it was never committed.
- `hostapd/config/hostapd.conf` is safe to read — `wpa_passphrase=$WPA_PASSPHRASE` is an envsubst placeholder. The real value is in the ignored `.env`.
