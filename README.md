# docker-containers

Small, self-contained Docker Compose stacks that IT Dojo uses in class and on the bench — one directory per stack. Each is independent:

```bash
cd <stack>
docker compose up -d
```

The repo is deliberately small (~1.3 MB). Clone the whole thing; there is nothing here that warrants a sparse checkout.

## Stacks

| Stack | What it runs |
| --- | --- |
| `chirpstack` | ChirpStack 4 LoRaWAN network server — gateway bridge, REST API, PostgreSQL, Redis, and Mosquitto. Based on upstream's Docker example. |
| `excalidraw` | Excalidraw whiteboard, from the published image. |
| `geofence-draw` | Geofence drawing tool, built from the Dockerfile here. |
| `gitea` | Self-hosted Gitea with PostgreSQL. |
| `https-right-quick` | A TLS-secured Python web server for **very temporary** use — securely pulling files off a remote device. |
| `kismet-gpsd-repo` | Kismet + gpsd, with Kismet installed from the official kismetwireless.net apt repository. |
| `kismet-gpsd-source` | Kismet + gpsd, with Kismet built from source. Config paths differ from the repo variant — see its README. |
| `mediamtx` | MediaMTX media server (RTSP/WebRTC), ffmpeg build. |
| `mqtt` | Mosquitto MQTT broker. |
| `tftp-server` | A TFTP server, for the rare occasion you need one. Built here. |

## Conventions

A stack is a compose file plus its own config. Third-party project source trees are never vendored — if a stack looks like it needs upstream's source, it is running upstream's development harness by mistake; use the published image. Stacks that do `build:` build from a Dockerfile and sources in this repo, which is a different thing entirely.

Machine-specific settings belong in a gitignored `.env` beside a tracked `.env.example`. The one exception is `https-right-quick/.env`, whose credentials are demo values that are part of the exercise.
