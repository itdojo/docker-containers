# mediamtx — Pi camera streaming

A Raspberry Pi with one camera attached, publishing it as RTSP, HLS and WebRTC
on the Pi's own LAN address. MediaMTX owns the camera directly — `rpiCamera`
for a CSI sensor, an on-demand ffmpeg pipeline for USB — and host networking
keeps the streams on the Pi's real IP rather than behind a Docker NAT.

Two audiences, and the config is tuned for the first:

- **A browser**, watching live. `http://<pi>:8889/cam` for WebRTC,
  `http://<pi>:8888/cam` for HLS. This is the classroom case.
- **A Frigate NVR** on another host, pulling RTSP continuously and recording
  it. See [Feeding Frigate](#feeding-frigate) — two numbers change.

```
.
├── compose.yaml                host networking, privileged, /dev/shm tmpfs
├── .env.example                -> copy to .env  · WebRTC reachability
├── mediamtx-users.sh           creates config/users.env (argon2 hashes)
├── config/
│   ├── mediamtx.yml            the file you edit; paths live at the bottom
│   └── users.env.example       -> generated, not hand-written
└── docs/working-notes.md       decisions, gotchas, constraints
```

## Quick start

```bash
cp .env.example .env
$EDITOR .env                 # MTX_WEBRTCADDITIONALHOSTS — the Pi's own IP
$EDITOR config/mediamtx.yml  # the camera path, at the bottom
docker compose up -d
```

`MTX_WEBRTCADDITIONALHOSTS` is the one setting that is wrong by default and
fails confusingly: WebRTC advertises an address for the browser to dial back,
and if that address is not reachable from where viewers sit, the page loads and
the video never starts. Set it to whatever address viewers can actually reach —
the LAN IP, or the `wg0` address if they arrive over WireGuard.

## Cameras

Paths live at the bottom of `config/mediamtx.yml`. Each becomes:

```
rtsp://<pi>:8554/<name>     VLC, ffmpeg, Frigate
http://<pi>:8889/<name>     WebRTC — browser, low latency
http://<pi>:8888/<name>     HLS — browser, higher latency, more compatible
```

**CSI cameras** use `source: rpiCamera`, which works for any libcamera sensor.
The shipped `cam` path is 1280×720 at 30 fps. Get the sensor index for
`rpiCameraCamID` from `rpicam-hello --list-cameras`.

**USB cameras** run an ffmpeg pipeline on demand, and the config ships two
variants because the right one depends on what the camera can emit. Find out
first:

```bash
v4l2-ctl --device=/dev/video0 --list-formats-ext
```

`H264` means the camera encodes for you and ffmpeg can `-c:v copy` — no
encoding on the Pi at all. Most Logitech business webcams (C920, C922, C925e)
do this. `MJPG` means a cheap decode and then an encode. `YUYV` is raw and is
what you get if `-input_format` is omitted: it saturates USB 2.0 bandwidth,
often caps around 10 fps at 720p, *and* still has to be encoded. Uncomment the
variant that matches, not both — they define the same path name.

**Path keys all sit at 2-space indent.** A path at a different indent produces
`while parsing a block mapping` pointing at line 15, nowhere near the actual
mistake.

## Feeding Frigate

When a [Frigate NVR](../frigate/) is pulling these streams, change two numbers
on the camera path:

| Setting | Live viewing | Feeding an NVR | Why |
|---|---|---|---|
| `rpiCameraFPS` | 30 | **15** | Frigate recommends 15 for a record stream and detects at 5 regardless. Halves encode CPU on a Pi 5, and halves tunnel bandwidth for a remote camera. |
| `rpiCameraIDRPeriod` | 60 | **15** | One keyframe per second. Frigate cuts recording segments on keyframes and cannot begin decoding without one, so shorter means tighter clips and faster live view. Costs bitrate; use 30 if the link is tight. |

Nothing else needs changing, and three settings that look like candidates
should be left alone:

- `record: false` in `pathDefaults` is correct — Frigate owns recording. Turning
  it on here writes a second copy to the Pi's SD card.
- `rtspTransports: [tcp]` already matches what Frigate's `preset-rtsp-generic`
  asks for.
- `sourceOnDemand: false` is what keeps the camera running when nothing is
  watching. On-demand would make Frigate wait for the stream to spin up and
  lose the first seconds of every event.

**Resolution is already right.** 1280×720 is a good detect resolution — Frigate
runs a 320×320 model, so anything beyond 720p is decoded and thrown away.

### About substreams

The usual Frigate advice is to publish a second low-resolution path for
detection. **Do not do that on a Pi 5.** BCM2712 has no hardware video encoder
at all — it kept an HEVC decoder and dropped the rest — so `rpiCameraCodec:
auto` is already falling back to software `libx264`, and a substream would add
a software decode plus a second software encode to save work on a different
machine. Publish 720p once and let Frigate detect on it.

A commented `cam-sub` path is in the config for the cases where the trade does
work: a Pi 4 (hardware both ways via v4l2m2m), an x86 camera host, or any
camera behind a metered or narrow link, where shrinking the continuously-pulled
detect stream buys back real bandwidth.

### Credentials

Give Frigate its own read-only user rather than running the server open:

```bash
./mediamtx-users.sh
```

Then set `FRIGATE_RTSP_USER` and `FRIGATE_RTSP_PASSWORD` in the Frigate
package's `.env`. Enabling authentication takes two more steps the script
cannot do for you — uncomment `authMethod` and `authInternalUsers` in
`config/mediamtx.yml` — and the script's closing output repeats them.

## Related

- `~/projects/docker-containers/frigate/` — the NVR that consumes these feeds.
- `docs/working-notes.md` — why these decisions were made, and the gotchas that
  are not visible from the config.
