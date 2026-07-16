# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## What this repo is

A library of small, self-contained Docker Compose stacks — one directory per stack — used in IT Dojo classes and on the bench. It replaces a repo-per-compose-file sprawl: a whole git repo for one YAML file is overhead without benefit. Each stack is independent (`cd <stack> && docker compose up -d`).

The repo is **public**, and therefore `policy: notify` in the fleet manifest — it is never auto-checkpointed, and commits here are deliberate. Treat it as a curated, published artifact, not a scratch aggregation area.

## Rules

- **A stack is a compose file plus its own config, and nothing else.** A third-party project's source tree is never vendored here. If a stack seems to need upstream's source, it is running upstream's *development* harness by mistake — use the published image instead. `excalidraw/` was exactly this: a 170 MB clone of `excalidraw/excalidraw` running upstream's contributor compose, collapsed to six lines against `excalidraw/excalidraw:latest` on 2026-07-16 (172 MB → 1.3 MB).
- **`build:` is not the problem — whose source is.** Five stacks (`geofence-draw`, `https-right-quick`, `kismet-gpsd-repo`, `kismet-gpsd-source`, `tftp-server`) build from a Dockerfile and sources that live here, which is correct and must not be "fixed". The anti-pattern is specifically `build:` against a *cloned third-party project*, typically with its working tree volume-mounted back into the container.
- **Folding in an existing repo?** Remove its nested `.git` first, or use `git subtree add` if its history is worth keeping here. A plain `git add .` over a nested repo silently creates a gitlink, which clones as an empty directory for everyone else.
- **`.env` is gitignored with one deliberate exception.** `https-right-quick/.env` holds demo credentials that are part of the lab and is tracked on purpose. Machine-specific env files (`mediamtx/.env`) stay ignored; ship a tracked `.env.example` beside them.
- **Public by default.** Every stack added here becomes world-readable, so apply the sensitivity line when a stack is *added*, not when it is pushed: distributable class-scoped secrets may be published; anything that unlocks money or machines may not.

## Class delivery

Containers reach students via the `bundle-fetch` shortcode rendered from the course site, not from this repo — that mechanism works on a classroom LAN with no internet, which a `git clone` does not. This library serves the instructor and fleet; the classroom is served by courseware.

## Knowledge hub

Durable notes, decisions, and synthesis for this project live in Dojobrain, not here:
`~/vaults/dojobrain/10-projects/docker-containers/docker-containers-moc.md`.
This repo carries only source + spec; harvest in-repo material into the vault
deliberately via Ingest — never bulk-move (see pre-existing-repo-notes-as-ingest-candidates).
