# Kismet + GPSD — apt-repo Docker bundle

This bundle builds a Kismet container by installing Kismet **from the
official kismetwireless.net apt repository** (not from source).  Pair
it with a small Alpine `gpsd` sibling container to tag every capture
with location.

Use this bundle when you want:

- A fast first build (~3-5 minutes), even on low-power SBCs like
  Gateworks Venice.
- No need for an 8 GB swap file (the source-build path needs one to
  avoid OOM kills during compilation).
- Tracking the upstream "release" / "git" debs that the Kismet
  project publishes for Ubuntu.

The companion bundle `../kismet-source-gpsd/` builds Kismet from
source instead — slower, but lets you carry custom patches.

---

## Where Kismet puts its files: repo install vs source install

The two install styles put files in **different paths**, and the
compose file has to mirror that or the container will silently load
the wrong `kismet_site.conf` (or none at all).

| What                          | apt-repo install (this bundle)       | Source install (`make suidinstall`)  |
| ----------------------------- | ------------------------------------ | ------------------------------------ |
| Site-override config          | `/etc/kismet/kismet_site.conf`       | `/usr/local/etc/kismet_site.conf`    |
| Default config                | `/etc/kismet/kismet.conf`            | `/usr/local/etc/kismet.conf`         |
| Main binary                   | `/usr/bin/kismet`                    | `/usr/local/bin/kismet`              |
| Capture helpers (setuid)      | `/usr/bin/kismet_cap_*`              | `/usr/local/bin/kismet_cap_*`        |
| Data and alert files          | `/usr/share/kismet/`                 | `/usr/share/kismet/` (vendor copies) |

The two compose files (this bundle and `kismet-source-gpsd/`) are
**identical except for two lines** — the volume mount and the
`KISMET_CONF_DIR` environment variable.

### `compose.yaml` — apt-repo install (this bundle)

```yaml
    volumes:
      - ./kismet_config/kismet_site.conf:/etc/kismet/kismet_site.conf
    environment:
      - KISMET_CONF_DIR=/etc/kismet
```

### `compose.yaml` — source install

```yaml
    volumes:
      - ./kismet_config/kismet_site.conf:/usr/local/etc/kismet_site.conf
    environment:
      - KISMET_CONF_DIR=/usr/local/etc
```

> [!Warning]
> If you copy a `compose.yaml` from one bundle to the other without
> updating these two lines, Kismet starts but never reads your
> `kismet_site.conf` — captures fail silently because no `source=`
> line is loaded.  This is the single most common failure mode when
> students mix the two bundles.

---

## Files in this bundle

```tree
- kismet-repo-gpsd | folder
  - .env
  - Dockerfile.gpsd
  - Dockerfile.kismet
  - README.md
  - compose.yaml
  - kismet_config | folder
    - kismet_site.conf
  - kismet_logs | folder
```

The lab that drives this bundle is
[`09a - Running Kismet (apt repo install) and GPSD in Docker`](../../../09a-kismet-gpsd-in-docker-from-apt-repo.md).
