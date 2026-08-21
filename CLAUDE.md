# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What this repo is

A library of small, self-contained Docker Compose stacks — one directory per stack — used in IT Dojo classes and on the bench. It replaces a repo-per-compose-file sprawl: a whole git repo for one YAML file is overhead without benefit. Each stack is independent (`cd <stack> && docker compose up -d`).

The repo is **public** as of 2026-08-21, and therefore `policy: notify` in the fleet manifest — fleet fetches and fast-forwards it but never auto-commits, so every publish is a deliberate `git push` by hand. It was private and `auto` for five days (2026-08-16 to 2026-08-21). The four host-preparing stacks (`ntopng`, `frigate`, `hostapd`, `pihole-dnscrypt`) are public along with everything else; their real values live in gitignored `.env` files and bind-mounts, and the tracked `.example` files carry placeholders.

## Rules

- **A stack is a compose file plus its own config, and nothing else.** A third-party project's source tree is never vendored *on disk* here. If a stack seems to need upstream's source checked in, it is running upstream's *development* harness by mistake. `excalidraw/` was exactly this: a 170 MB clone of `excalidraw/excalidraw` running upstream's contributor compose, collapsed on 2026-07-16 (172 MB → 1.3 MB).
- **`build:` is not the problem — whose source is, and where it lives.** Most build-stacks (`geofence-draw`, `https-right-quick`, `kismet-gpsd-repo`, `kismet-gpsd-source`, `tftp-server`) build from a Dockerfile and sources that live here, which is correct and must not be "fixed". `excalidraw/` is the deliberate edge case: it builds from upstream, but its Dockerfile does the `git clone` *inside* the image at build time and serves the static bundle with nginx, so the tree stays two files. The anti-pattern is specifically a *cloned third-party project on disk*, typically with its working tree volume-mounted back into the container. Judge by what is checked in, not by the presence of `build:`.
- **Runtime state is not config, and never gets committed.** A bind-mount target the container writes into is ignored; the readable copy of record is the `.example` beside it. Live cases: `pihole-dnscrypt/etc-pihole/` (fills with a generated admin password hash and a `tls.pem` private key), `pihole-dnscrypt/etc-dnsmasq.d/`, `mediamtx/log/`, `mediamtx/recordings/`, `frigate/config/config.yml` (Frigate's UI rewrites it and drops the comments).
- **Large media never enters history.** `*.mp4` is ignored at the root. `ntopng/docs/` holds 36 MB of explainer video that would outweigh every stack combined and could not be removed later without a history rewrite; the `.html` explainers beside them are tracked.
- **Folding in an existing repo?** Remove its nested `.git` first, or use `git subtree add` if its history is worth keeping here. A plain `git add .` over a nested repo silently creates a gitlink, which clones as an empty directory for everyone else.
- **`.env` is gitignored with one deliberate exception.** `https-right-quick/.env` holds demo credentials that are part of the lab and is tracked on purpose. Machine-specific env files (`mediamtx/.env`) stay ignored; ship a tracked `.env.example` beside them.
- **Public, so committing is publishing.** The sensitivity check runs when a stack is *added*, not when it is pushed: nothing that unlocks money or machines, and nothing that pins a real host — a routable address, an SSID, a WireGuard peer, a camera URL — goes in a tracked file. Those belong in a gitignored `.env` with a placeholder-bearing `.example` beside it, which is the pattern every host stack here already follows.

## Class delivery

Containers reach students via the `bundle-fetch` shortcode rendered from the course site, not from this repo — that mechanism works on a classroom LAN with no internet, which a `git clone` does not. This library serves the instructor and fleet; the classroom is served by courseware.

## Knowledge hub

Durable notes, decisions, and synthesis for this project live in Dojobrain, not here:
`~/vaults/dojobrain/10-projects/docker-containers/docker-containers-moc.md`.
This repo carries only source + spec; harvest in-repo material into the vault
deliberately via Ingest — never bulk-move (see pre-existing-repo-notes-as-ingest-candidates).
