# mediamtx — working notes

## Decisions

- 2026-08-13: Credentials live in `config/users.env` as `MTX_AUTHINTERNALUSERS_*` env vars, loaded by compose as a second `env_file`, not as YAML in `mediamtx.yml`. Keeps hashes out of the file students read and edit, and out of the file most likely to be pasted into a lab doc.
- 2026-08-13: `mediamtx.yml` ships authentication **commented out**, including `authInternalUsers: []`. Uncommenting is the deliberate enable step; the lab default stays anonymous.
- 2026-08-13: `mediamtx-users.sh` always writes a final "managed tail" entry (`user: any`, ips `127.0.0.1,::1`, actions api/metrics/pprof). With `authInternalUsers: []` the built-in localhost API user is gone, and without this the API answers nothing on the Pi itself.
- 2026-08-13: argon2 stays at the CLI defaults (m=4096, t=3, p=1). Verification runs per request and HLS requests segments constantly; a heavier profile is paid on every segment on a Pi, not once at login.
- 2026-08-13: Script embeds the qol theme block verbatim rather than sourcing `linux/base_functions.sh`, because it must also run on macOS. Region copied is lines 44–371 of `~/projects/qol/linux/base_functions.sh`; keep it byte-identical.

- 2026-08-16: Live-viewing defaults win on the `cam` path. `rpiCameraFPS` stays at 30 and the NVR tuning (15 fps, IDR 15) is documented in a FEEDING FRIGATE block rather than applied. Every Pi already deployed keeps its current behavior; only a host that actually feeds Frigate is asked to change.
- 2026-08-16: The USB path ships as two labeled variants — native H.264 with `-c:v copy`, and MJPEG with a software encode — instead of one example. Which one a camera can do is a property of the camera, not a preference, and `v4l2-ctl --list-formats-ext` is the way to find out.
- 2026-08-16: `cam-sub` ships commented and explicitly fenced off from the Pi 5. It re-encodes, and a Pi 5 has no hardware encoder, so it would spend a software decode plus a software encode locally to save work on the Frigate host. Worth it only on a Pi 4 (v4l2m2m both ways), an x86 camera host, or a camera behind a narrow link.

## Gotchas

- **Path keys must all sit at the same indentation, and until 2026-08-16 they did not.** `cam:` was indented 4 spaces under `paths:` while every commented path (`#usb:`, `#all_others:`) sat at 2. Uncommenting any of them produced `while parsing a block mapping`, pointing at `logLevel` on line 15 rather than at the path — the error names where the parser gave up, not where the mistake is. The whole block is normalized to 2 spaces now, and all three commented paths were verified to uncomment into valid YAML. Keep new paths at 2.
- **A Raspberry Pi 5 has no hardware video encoder.** BCM2712 kept an HEVC decoder and dropped the rest, including the H.264 encoder every earlier Pi had. `rpiCameraCodec: auto` therefore always resolves to the libx264 software fallback on a Pi 5 — it works, it is just not free, and nothing in the config said so before. This is why the frame-rate advice and the substream fencing are Pi-5-specific.
- **`-input_format` is the difference between a copy and a full encode on USB cameras.** Without it, ffmpeg takes the driver's default, which is normally raw YUYV: uncompressed frames that saturate USB 2.0 (720p often caps near 10 fps) and still need encoding from scratch. Logitech C920/C922/C925e emit H.264 on the camera, so `-input_format h264 -c:v copy` costs the Pi nothing. The original USB example omitted the flag.
- **Docker Compose interpolates unquoted `env_file` values.** An argon2 hash begins with `$argon2id`, which parses as a variable reference and expands to nothing — the password silently becomes unverifiable. Every value in `users.env` is single-quoted; Compose treats single-quoted values literally. Do not "tidy" the quotes away.
- **MediaMTX merges `MTX_AUTHINTERNALUSERS_*` into the existing user list field by field; it does not replace it** (`internal/conf/env/env.go` never truncates a slice). Verified 2026-08-13: with the built-in list still in place, a user defined as publish+read came back from `/v3/config/global/get` holding publish+read+**playback**, inherited from built-in entry 0's third permission. `authInternalUsers: []` in `mediamtx.yml` is what makes `users.env` authoritative. This is the single most breakable thing in the setup.
- Fail-closed confirmed 2026-08-13: `authInternalUsers: []` with no `users.env` present starts the server normally and 401s everything, including the local API.
- `env_file` long syntax (`path:` / `required:`) needs Compose v2.20+. `required: false` on `users.env` is what lets the stack start before the script has ever run.
- A function whose stdout is its return value must send `log_warn` to stderr. `ask_username` originally did not, and a rejected username concatenated the warning text into the captured value. Same rule applies to `ask_ips` and `ask_role_perms`.
- `ask_password` cannot be called as `$(...)`: the `stty` state it saves would die with the subshell, and Ctrl-C at the password prompt would return a shell with echo off. It returns through the global `PASSWORD_IN`.
- `read -rs` only disables echo once it starts running, so input arriving between the prompt `printf` and the `read` is still echoed. Real for expect-driven tests, marginal for humans; handled with `stty -echo` around the whole prompt.
- Testing the container on macOS: `network_mode: host` does not work, and port-mapped requests reach MediaMTX from the Docker gateway address, not `127.0.0.1` — so the localhost tail entry cannot authorise them. Test with a user that has an `api` permission and no IP restriction.

## Ruled out

- Storing users as a YAML fragment MediaMTX includes: there is no include directive, it reads exactly one config file.
- Driving multiple users from `.env` without `authInternalUsers: []`: workable only by writing every field of every index including padding permissions to match the built-in entries' counts. Provably safe but unreadable, and one short list silently reopens a permission.

## Constraints

- Deployment target is a Raspberry Pi with one camera; the script must also run on macOS for authoring.
- Passwords: minimum 6 characters, argon2id, plaintext never written to disk.
- Filenames stay lowercase-hyphen; scripts follow the qol house style (`~/projects/qol/script-design.md`).
