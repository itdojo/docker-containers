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

<!-- knowledge-hub:begin (public variant). create-project writes this block and refreshes it on a rerun. This repo is public, so the block names no private paths; the global contract's "Public repos" section resolves them. Repo-specific lines go after the end marker. -->
This repo is public. It holds code, the tracker config the dojo- skills read in `docs/agents/`, and `docs/working-notes.md`, which is session scratch. Durable knowledge lives in the Dojobrain vault, where this project's slug is `docker-containers`. Your global contract's "Public repos" section says where the vault is and where this project's MOC sits in it. Read that MOC before substantive work. If it is unreachable, stop and tell the user.

Durable knowledge goes to the vault:

- A decision worth a full record becomes a `setup-decision` note, filed by what it governs as the vault's contract describes. A small implementation call stays in working notes under Decisions.
- A new term goes through the gloss skill, which files it in this project's glossary or, when other repos share the term, in the vault's shared glossary.
- A gotcha or ruled-out approach that would bite another repo goes into working notes tagged `(cross-project)` when it happens. dojo-retro proposes it for the vault at the end of the session, and Weekly catches what retro missed.
- A raw source, such as an article, a PDF or research findings, goes to the vault's inbox.

Before your first write in the vault, read the vault's `AGENTS.md`. It governs every file in the vault, including which writes wait for the user's yes, and this file governs the files in this repo. A Claude session with the vault added already has it loaded. Codex never loads it on its own. Git runs in this repo only, and the fleet checkpoint commits the vault.

Before substantive work, brief yourself. Spawn it even when a few greps look like enough: recall sweeps every repo's working notes, which a search from here doesn't reach. In Claude Code, spawn the `recall` agent with the task in one sentence as its whole brief. Elsewhere, spawn a read-only subagent whose whole brief is "Read `~/.agents/skills/dojo-grilling/recall.md` and follow it. Topic: <the task in one sentence>". Either way, that file sets recall's scope and digest shape; work from the digest it returns. If that file is missing, give the subagent the vault's `vault-query` agent as its procedure instead, with the task and the slug `docker-containers`. A planning dojo- skill that already ran recall covers this. A question about past work, an earlier choice, or which of two tools to use counts as substantive, however short. One-line fixes skip it.

Everything committed here is published, working notes included. Name another repo by its name and a repo-relative path, such as qol's `script-design.md`, and a vault note by its note name, never by a home-relative or absolute path. A line that has to keep one carries `public-path-ok`, and the `no-private-paths` pre-commit hook refuses any other.
<!-- knowledge-hub:end -->

This repo carries only source and spec. Harvest in-repo material into the vault deliberately through Ingest, never by bulk move (`pre-existing-repo-notes-as-ingest-candidates`).
