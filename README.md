# docker-containers

Small, self-contained Docker Compose stacks that IT Dojo uses in class and on the bench — one directory per stack. Each is independent:

```bash
cd <stack>
docker compose up -d
```

The repo is deliberately small (~3 MB tracked). Clone the whole thing; there is nothing here that warrants a sparse checkout. It is **private** — see [Visibility](#visibility) before adding a stack or handing anyone the URL.

## Stacks

Fourteen, in two rough groups: single-service utilities you bring up and forget, and multi-service appliances that need a host prepared first.

### Utilities

| Stack | What it runs |
| --- | --- |
| `excalidraw` | Excalidraw whiteboard. Builds upstream's static bundle inside the image and serves it with nginx on `:3333` — no backend, no database, no collaboration server. |
| `geofence-draw` | Geofence drawing tool, built from the Dockerfile here. |
| `gitea` | Self-hosted Gitea with PostgreSQL. |
| `https-right-quick` | A TLS-secured Python web server for **very temporary** use — securely pulling files off a remote device. |
| `mqtt` | Mosquitto MQTT broker. |
| `tftp-server` | A TFTP server, for the rare occasion you need one. Built here. |

### Wireless and capture

| Stack | What it runs |
| --- | --- |
| `hostapd` | An access point in a container: hostapd drives the radio, dnsmasq serves DHCP and DNS, and `entrypoint.sh` masquerades onto an uplink interface. Every setting is templated out of `.env` by `envsubst` — nothing is hardcoded in `config/`. |
| `kismet-gpsd-repo` | Kismet + gpsd, with Kismet installed from the official kismetwireless.net apt repository. |
| `kismet-gpsd-source` | Kismet + gpsd, with Kismet built from source. Config paths differ from the repo variant — see its README. |
| `chirpstack` | ChirpStack 4 LoRaWAN network server — gateway bridge, REST API, PostgreSQL, Redis, and Mosquitto. Based on upstream's Docker example. |

### Appliances

These prepare a host, not just a container. Each carries its own README and a setup script or host config; read the stack README before running anything.

| Stack | What it runs |
| --- | --- |
| `frigate` | Frigate 0.17.2 NVR consolidation box — pulls RTSP from however many camera hosts you have, runs object detection, records, and serves one viewer for the lot. Ships a private MQTT broker and a WireGuard sidecar so LAN cameras and tunnelled cameras land in the same instance. One compose overlay per accelerator: `cpu`, `coral-usb`, `hailo`, `openvino`, `rpi`. Driven by `frigate-setup.sh`. |
| `mediamtx` | MediaMTX media server (RTSP/WebRTC), ffmpeg build. `mediamtx-users.sh` generates the hashed credential file. |
| `ntopng` | An ntopng sensor sitting *inline* on an L2 bridge over two physical ports, monitoring the bridge master only. Two network positions — outside the firewall or cut into a LAN link — selected by `POSITION` in `.env`. Carries host netplan, sysctl tuning, and a systemd unit under `host/` and `etc/`. |
| `pihole-dnscrypt` | Pi-hole with dnscrypt-proxy as its only upstream, answering DNS on a WireGuard interface rather than the LAN. |

## Conventions

**A stack is a compose file plus its own config.** Third-party project source trees are never vendored here — if a stack looks like it needs upstream's source on disk, it is running upstream's development harness by mistake. Stacks that do `build:` build from a Dockerfile and sources in this repo, which is a different thing entirely. `excalidraw` is the edge case worth knowing: it does `build:` against upstream, but the clone happens *inside* the image at build time, so nothing upstream is checked in here.

**Machine-specific settings belong in a gitignored `.env` beside a tracked `.env.example`.** The one exception is `https-right-quick/.env`, whose credentials are demo values that are part of the exercise; that re-include lives in `https-right-quick/.gitignore`, because a nested `.gitignore` beats a root-level negation.

**Runtime state is not config.** A bind-mount target the container writes into — `pihole-dnscrypt/etc-pihole/`, `mediamtx/log/`, `frigate/config/config.yml` — is ignored, and the readable copy of record is the `.example` beside it. The tell that you have this backwards is a diff full of changes nobody made.

**Large media stays out of git.** `*.mp4` is ignored at the root; the ntopng explainer videos live on disk and travel out of band. Anything that would outweigh the stacks themselves does not go in, because it cannot be taken back out without a history rewrite.

## Visibility

The repo is private as of 2026-08-16, and `policy: auto` in the fleet manifest — fleet checkpoints and pushes it like any other private repo, so uncommitted work does not sit on one machine. It was public and `notify` until then; the change was made because the stacks that have accumulated since (`ntopng`, `frigate`, `hostapd`, `pihole-dnscrypt`) prepare real hosts and carry real network topology, which is not classroom material.

Consequence worth stating plainly: **a stack added here is no longer published by being committed.** Class delivery was never this repo's job — containers reach students via the `bundle-fetch` shortcode rendered from the course site, which works on a classroom LAN with no internet — but anything you want public now needs a deliberate second move.

## Knowledge hub

Durable notes and the decisions behind this repo live in Dojobrain, not here:
`~/vaults/dojobrain/10-projects/docker-containers/docker-containers-moc.md`.
