# Frigate NVR

A Frigate consolidation box: it pulls RTSP from however many mediamtx camera
hosts you have, runs object detection on them, records, and serves one viewer
for the lot. Frigate 0.17.2, a private MQTT broker, and a WireGuard sidecar so
that cameras on the local LAN and cameras across a tunnel land in the same
instance.

This is a template. Copy the folder to the host, edit two files, run
`./frigate-setup.sh`.

The hardware it is written for varies more than the software does — Raspberry
Pi 4 and 5, LattePanda Delta and Sigma, Gateworks Venice — and the thing that
actually differs between them is which chip does object detection. That is the
only axis this package makes configurable, and it is configurable in one line.

```
.
├── compose.yaml                base — frigate + mosquitto. No ports, no detector.
├── compose.wireguard.yaml     ─┬─ network overlay · pick exactly one · default
├── compose.ports.yaml         ─┘
├── compose.openvino.yaml      ─┐
├── compose.coral-usb.yaml      │
├── compose.hailo.yaml          ├─ detector overlay · pick exactly one
├── compose.rpi.yaml            │
├── compose.cpu.yaml           ─┘
├── .env.example                -> copy to .env
├── config/
│   └── config.yml.example      -> copy to config.yml   · cameras and detector
├── mosquitto/mosquitto.conf    listener + persistence; broker is not published
├── wireguard/wg0.conf.example  -> copy to wg0.conf     · tunnel profile only
├── frigate-setup.sh            run this; it checks first and starts second
└── docs/working-notes.md       decisions, gotchas, constraints
```

## Quick start

```bash
./frigate-setup.sh            # creates .env and config/config.yml, then stops
$EDITOR .env                  # COMPOSE_FILE first, then FRIGATE_MEDIA
$EDITOR config/config.yml     # the matching detector block, then your cameras
./frigate-setup.sh            # seeds wireguard/wg0.conf, then stops again
$EDITOR wireguard/wg0.conf    # keys, Endpoint, AllowedIPs
./frigate-setup.sh            # checks the host, then starts the stack
```

The two middle steps disappear on a host with no remote cameras — set
`COMPOSE_FILE` to the `compose.ports.yaml` variant and no tunnel config is ever
asked for.

Do not run it as root — it uses `sudo` per step and refuses an EUID of 0. It is
idempotent; rerun it as often as you like. `./frigate-setup.sh --check` runs
every check and starts nothing.

The second run ends by printing the admin password Frigate generated. Read the
**Security** section below before you use it.

## How the profiles work

`COMPOSE_FILE` in `.env` is the whole portability story. Compose reads that key
out of `.env` by itself, so the command stays `docker compose up -d` on every
host and the per-host difference lives in the one file that is already
per-host.

```
COMPOSE_FILE=compose.yaml:compose.wireguard.yaml:compose.openvino.yaml
             └── base ───┘ └──── network ──────┘ └── detector ──────┘
```

Exactly one network overlay and exactly one detector overlay. The base file
alone is never used: it publishes no ports and defines no detector.

The network overlay is `compose.wireguard.yaml` by default because the normal
deployment ingests from local LAN cameras *and* cameras across a tunnel at the
same time. Swap in `compose.ports.yaml` on a host with no remote cameras.

| Host | Detector overlay | `config.yml` block | Notes |
|---|---|---|---|
| LattePanda Delta / Sigma | `compose.openvino.yaml` | `type: openvino` | iGPU via `/dev/dri/renderD128`. Sigma can use `device: NPU`. |
| Anything, with a Coral USB | `compose.coral-usb.yaml` | `type: edgetpu` | The portable one. Works identically on all four host families. |
| Pi 5 + AI HAT+ | `compose.hailo.yaml` | `type: hailo8l` | Needs `hailo-all` on the host and `/dev/hailo0`. |
| Pi 4, no accelerator | `compose.rpi.yaml` | `type: cpu` | Hardware H.264 decode, CPU detection. Two or three cameras. |
| Gateworks Venice, Pi 5 bare | `compose.cpu.yaml` | `type: cpu` | No accelerator at all. One to four cameras. |

**The overlay and `config.yml` have to agree, and nothing enforces that at
runtime.** A mismatch starts cleanly, loads the wrong detector, and detects
nothing. `frigate-setup.sh` compares the two and refuses to start on a
mismatch — that check is most of why the script exists.

### Image tag

`FRIGATE_IMAGE` is pinned to `0.17.2`, not `stable`. On an NVR, the symptom of
an unwanted upgrade is footage you do not have.

The right tag differs by architecture. On arm64 the plain tag is the
Raspberry-Pi-optimized build; a Gateworks Venice board is generic arm64 and
wants `0.17.2-standard-arm64`.

## Storage

`FRIGATE_MEDIA` in `.env` is a host path, bind-mounted to `/media/frigate`.

**Put it on an external disk.** Continuous recording writes constantly, and an
SD card under that load fails in months — that is the ordinary outcome, not a
worst case. A USB SSD is the cheapest fix available. `frigate-setup.sh` warns
when recordings are aimed at the root filesystem of a Raspberry Pi.

```bash
sudo mkdir -p /mnt/frigate
sudo chown -R $(id -u):$(id -g) /mnt/frigate
```

Two other memory settings matter and both have real failure modes:

`FRIGATE_CACHE_SIZE` mounts `/tmp/cache` as tmpfs. Frigate assembles every
in-progress recording segment there before moving it to `FRIGATE_MEDIA`. On
disk that is a second write of every byte you record; as tmpfs it costs RAM
instead. Roughly 100 MB per camera.

`FRIGATE_SHM_SIZE` sizes `/dev/shm`, where decoded frames live. Docker's 64 MB
default is not enough for one camera, and the failure is decode stalls rather
than an obvious out-of-memory error.

```
per camera MB = (detect_width * detect_height * 1.5 * 20 + 270480) / 1048576
```

At the 640×480 detect resolution this stack recommends that is about 9 MB per
camera. Sum them, add 40 MB for birdseye, round generously up. Over-allocating
costs reserved RAM; under-allocating costs cameras that stop.

## Cameras

`config/config.yml` is where cameras are defined. The example ships two,
pulling from mediamtx hosts by IP.

Frigate's bundled go2rtc sits in front of every camera, which means **one**
connection to mediamtx per stream no matter how many people are watching. Two
browser tabs on a camera without a restream would be two pulls against the
camera itself. It is also what makes the live view WebRTC instead of a stack of
JPEGs, and what re-publishes each feed at
`rtsp://<frigate-host>:8554/<camera>` plus `/birdseye`.

### Detection resolution, and when a substream is worth it

Recording a stream costs almost nothing — the bytes are copied to disk, never
decoded. Detecting on a stream costs a great deal, because every frame has to
be decoded and then run through the detector. What follows from that is: **keep
the resolution the detector sees small.** There are two ways to do it, and
which one is right depends on the camera host, not on Frigate.

**One stream, published small.** mediamtx publishes the camera once at around
720p and Frigate gives that single input both roles. One encode on the camera
host, one decode here.

```yaml
inputs:
  - path: rtsp://127.0.0.1:8554/front_door
    roles: [record, detect]
```

**Two streams, split by role.** mediamtx publishes a full-resolution path and a
low-resolution `-sub` path. Recording copies the big one; detection decodes the
small one. This is the better answer when you want high-resolution footage to
review, and when the camera host can produce the second stream cheaply.

```yaml
inputs:
  - path: rtsp://127.0.0.1:8554/front_door        # full res
    roles: [record]
  - path: rtsp://127.0.0.1:8554/front_door_sub    # ~640x480
    roles: [detect]
```

**On a Raspberry Pi 5 camera host, prefer the first.** The Pi 5's BCM2712 has a
hardware HEVC decoder and nothing else — no H.264 decode, and **no hardware
video encoder at all**. Encoding the camera to H.264 is already software there,
and a `-sub` path adds a software decode plus a second software encode on top.
At one or two cameras per Pi that cost buys you nothing the Frigate side needs.
Publish 720p once.

The split earns its keep on hosts with a real encoder, on cameras that natively
publish two streams, and on anything reached across the tunnel — there the
detect stream is pulled continuously over a link whose bandwidth you do not
control, and making it small is worth an encode at the far end.

### Hardware video decoding

`ffmpeg.hwaccel_args` is left at `auto`, which is right on most hosts. Override
it in `config.yml` when `auto` guesses wrong:

| Preset | Hardware |
|---|---|
| `preset-vaapi` | Intel gen1–gen12, AMD |
| `preset-intel-qsv-h264` / `-h265` | Intel gen8+ |
| `preset-rpi-64-h264` / `-h265` | Raspberry Pi 3/4 |
| `preset-nvidia` | NVIDIA GPU |
| `preset-rkmpp` | Rockchip |

**A Raspberry Pi 5 has no hardware H.264 decoder** — the block was removed from
the SoC, which is why the presets stop at Pi 4. Decoding is software there, and
so it is on a Gateworks Venice board. Leave `auto` alone on both and keep the
detect resolution down.

## WireGuard

The default overlay, because the normal deployment ingests from **both** local
LAN cameras and cameras across a tunnel, into one Frigate instance.

```
COMPOSE_FILE=compose.yaml:compose.wireguard.yaml:compose.<detector>.yaml
```

A sidecar container creates the tunnel in its own network namespace, and
Frigate joins that namespace with `network_mode: "service:wireguard"` instead
of having a stack of its own. That is why the published ports move onto the
sidecar, and why the base `compose.yaml` ships without any — Compose rejects
`ports:` on a service using `network_mode`.

### Why LAN cameras still work

`wg-quick` installs routes only for the prefixes named in `AllowedIPs`. Its
policy-routing machinery is a special case that fires only when `AllowedIPs`
carries a default route. So with a split tunnel the namespace keeps its
ordinary default route out through the Docker bridge: tunnel subnets go to
`wg0`, and everything else — LAN cameras, Mosquitto, replies to a LAN browser
on 8971 — takes the normal path.

Nothing in `config.yml` marks a camera as local or remote. Routing is
`wg0.conf`'s job and Frigate never knows the difference.

Four things bite, in rough order of how much time they cost:

**Subnet overlap.** A prefix in `AllowedIPs` that also covers something local
silently captures it. The far-end LAN and your LAN both on `192.168.1.0/24` is
the classic, and the symptom — local cameras dropping the moment the tunnel
comes up, while the remote ones work perfectly — points nowhere near
`wg0.conf`. Same hazard if a prefix overlaps Docker's bridge pool, where the
symptom is a Mosquitto failure instead. `frigate-setup.sh` compares
`AllowedIPs` against the host's real interface subnets and Docker's address
pools, and refuses to start on an overlap. The fix is at the far end: renumber,
or narrow the prefix to the camera addresses.

**Routing.** `AllowedIPs` is a routing table, not an access list. `0.0.0.0/0`
installs a default route inside the namespace and simultaneously breaks LAN
cameras, Mosquitto, and the return path to a LAN browser — three
unrelated-looking failures from one line. With mixed ingest that takes out most
of your cameras, not an edge case. List the remote camera subnets and nothing
else.

**Restart coupling.** Restarting the sidecar destroys Frigate's whole network
stack, which now means the LAN cameras and the UI go down with it, not only the
remote ones. Docker will not restart the dependent container. Always follow
with `docker compose restart frigate`.

**Kernel module.** WireGuard is in-kernel on Pi OS and Ubuntu. A Gateworks
Yocto kernel may not have it, in which case the image falls back to a userspace
implementation — on the same cores already decoding video in software. Check
`modinfo wireguard` before blaming the detector.

And one that is not a problem: **do not set `DNS =` in `wg0.conf`.** It rewrites
`resolv.conf` for the whole namespace, Frigate stops resolving `mosquitto`, and
the resulting MQTT error points nowhere near the cause. Address far-end cameras
by IP.

### When the tunnel drops

If the link fails but the sidecar survives, LAN cameras keep recording and the
remote ones go offline and retry on `ffmpeg.retry_interval`. That is the
intended behavior, and it is why the tunnel being load-bearing for the whole
namespace is tolerable: a dead far end costs you the far-end cameras, not the
NVR.

`docker compose exec wireguard wg show` reports the handshake age. A `latest
handshake` older than a couple of minutes on a keepalive'd peer means the link
is down, whatever the interface claims.

## Security

Three things, and the first one is live on 0.17.2.

**Change the admin password immediately.** Frigate generates one on first start
and prints it to the container log. On 0.17.2 the `/api/logs/{service}`
endpoint is readable by *any* authenticated user, including the `viewer` role —
[GHSA-c4qf-xxq4-vf55](https://github.com/blakeblackshear/frigate/security/advisories/GHSA-c4qf-xxq4-vf55),
CVSS 8.1, unfixed as of 0.17.2. A viewer account can therefore read the admin
password out of the log, and the nginx access log alongside it, which carries
camera RTSP credentials. Until it is patched: change the admin password at
Settings > Users before creating any other account, and treat every account you
create as an admin-equivalent regardless of the role you assign it.

**Port 5000 is unauthenticated and stays unpublished.** It is Frigate's
internal API with no login of any kind — anyone who reaches it can view every
camera and delete recordings. Use 8971, which is the same UI with TLS, login,
and role-based access. The certificate is self-signed; the browser warning is
expected.

**The MQTT broker is not published.** Frigate reaches it as `mosquitto:1883` on
a private Docker network, which is the only reason `allow_anonymous true` is
acceptable in `mosquitto/mosquitto.conf`. If you publish 1883, add a password
file *first* — the file says how, at the line you would be editing.

## Operating

```bash
docker compose logs -f frigate         # the log
docker compose exec wireguard wg show  # tunnel state, wireguard profile only
./frigate-setup.sh --check             # re-run every check, change nothing
```

**Upgrading** is a deliberate act, because the tag is pinned. Read the release
notes, edit `FRIGATE_IMAGE` in `.env`, then `docker compose pull && docker
compose up -d`. Check the notes for config-schema changes: 0.17 replaced
`record.retain` with separate `continuous`, `motion`, `alerts` and `detections`
blocks, and a config written against an older guide will not load.

**Frigate rewrites `config.yml` when you change settings in the UI**, and it
does not preserve comments. `config.yml.example` is the readable copy of record
and the file that is committed; `config.yml` is gitignored.

## Related

- `~/projects/docker-containers/mediamtx/` — the camera-side stack. Frigate's
  RTSP credentials are mediamtx users, created by its `mediamtx-users.sh`.
- `docs/working-notes.md` — why each of these decisions was made, what was ruled
  out, and the gotchas that are not visible from the config files.
