# ntopng inline-bridge sensor

An ntopng sensor that sits *inline* on an L2 bridge (`bridge0` over two
physical ports) and monitors the bridge master only. Ubuntu Server 24.04,
32 GB RAM. One package, two network positions, selected by `POSITION` in
`.env`.

|  | `POSITION=ext` | `POSITION=int` |
|---|---|---|
| Where | Between the ISP handoff and the firewall's WAN port | Inside the firewall, cut into a LAN link |
| `bridge0` | Addressless | DHCP lease |
| Reached via | A **separate** management NIC, static, no gateway | `bridge0` itself — `<hostname>.local` or a reservation |
| `LOCAL_NETS` | The **WAN prefix** (post-NAT; no RFC1918 on that wire) | Your **internal subnets** (pre-NAT) |
| `WEB_BIND` | Management IP or `127.0.0.1`. Wildcard **refused** | `0.0.0.0` expected. Wildcard warned, then allowed |
| Default route | None. Images must be side-loaded | Yes. `docker compose pull` works |
| mDNS | Off — a sensor on the dirty side does not announce itself | On, via the networkd drop-in |

Everything else is identical, which is why this is one package and not two.
The capture path — promiscuous bridge master, offloads off, bridge-netfilter
disabled, deep RX rings, `netprep` backstop, redis tuning, memory ceilings —
does not care which side of the firewall it is on. `compose.yaml` is
byte-identical at both positions.

This is a template. Copy it to the sensor host, edit `.env`, run
`./host-setup.sh`, and the host stages itself.

```
.
├── host-setup.sh                          run this; it does the rest
├── compose.yaml                           identical at both positions
├── .env.example                           -> copy to .env
├── etc/
│   └── netplan/
│       ├── 10-ntopng-bridge-ext.yaml      ─┬─ one is installed as
│       └── 10-ntopng-bridge-int.yaml      ─┘  /etc/netplan/10-ntopng-bridge.yaml
├── host/
│   ├── 98-capture-tuning.conf             -> /etc/sysctl.d/
│   ├── 99-transparent-bridge.conf         -> /etc/sysctl.d/
│   └── ntopng-tap.service                 -> /etc/systemd/system/
└── docs/
    └── working-notes.md                   decisions, gotchas, constraints
```

## Quick start

```bash
./host-setup.sh          # creates .env, then stops
$EDITOR .env             # POSITION first, then LOCAL_NETS and WEB_BIND
./host-setup.sh          # stages the host and brings the stack up
```

Do not run it as root — it uses `sudo` per step and will refuse an EUID of 0.
It is idempotent; rerun it as often as you like.

The script installs the netplan for your position, discovers the `.network`
unit name netplan actually generated, drops `Promiscuous=yes` (plus
`MulticastDNS=yes` for `int`) into a matching drop-in and proves systemd merged
it, loads `br_netfilter`, installs the sysctls, sizes the RX rings, applies the
network config, verifies the host, starts the stack, and installs a boot unit.
It refuses to start containers if the bridge is not promiscuous or the
bridge-netfilter keys are not zero.

**It will ask before applying netplan.** That step interrupts a live link at
either position — see the warning under `int` below, which is the sharper of
the two.

## What you must edit

Three things, and only these:

1. **`POSITION`** in `.env`. Everything below reads differently depending on
   it, and it is the first thing `host-setup.sh` validates.
2. **`LOCAL_NETS` and `WEB_BIND`** in `.env`, per your position. These are the
   two settings where a plausible-looking wrong value produces a sensor that
   runs perfectly and tells you nothing — or exposes its admin UI.
3. **The netplan file for your position** — the two physical port names, if
   yours are not `enp1s0` / `enp2s0`. Then make `MON_IF` and `BRIDGE_PORTS` in
   `.env` match what you just wrote there. Memory ceilings too, if the host is
   not 32 GB.

---

## `POSITION=ext` — outside the firewall

### Management interface

Not configured here, on purpose. `bridge0` is deliberately addressless — an
inline sensor with an IP on the monitored segment is a target, and this segment
is the dirty side — so reaching this box means a separate management NIC with a
**static address and no gateway**, in its own netplan file that this package
does not touch.

Point `WEB_BIND` at that address. If you leave it at the `127.0.0.1` default,
reach the UI over an SSH tunnel:

```bash
ssh -L 3000:127.0.0.1:3000 you@sensor-mgmt-ip
```

Never `0.0.0.0`. This box is on the dirty side of the firewall and ntopng ships
`admin` / `admin`. Two things enforce that: `compose.yaml` defaults `WEB_BIND`
to loopback so a missing or half-edited `.env` cannot silently publish the UI,
and `host-setup.sh` **refuses** to start the stack when `WEB_BIND` is a
wildcard and `POSITION=ext`.

### No default route

An addressless bridge plus a gateway-less management NIC means the host has
**no default route**, which is correct and also means `docker compose pull`
cannot reach a registry. Get the images there first:

```bash
# on a routed machine, from a copy of this package
docker compose config --images | xargs -n1 docker pull
docker save $(docker compose config --images) | ssh you@sensor-mgmt-ip 'docker load'
```

Asking compose for the list beats writing the tags out, which go stale the
first time anyone repins one. `host-setup.sh` builds its check the same way,
names the images that are missing, and refuses to hang on a pull that cannot
succeed. If a default route does exist, it just pulls.

### `LOCAL_NETS` is not your LAN

The most common way to get a working-but-useless sensor here. `bridge0` carries
the link between the ISP and your firewall's WAN interface. The firewall NATs,
or this box would not be "outside" — so no RFC1918 address ever appears on that
wire. Set `LOCAL_NETS` to your inside ranges and ntopng classifies every host
as remote, the Local Hosts view stays empty, and `--dns-mode=1` resolves
nothing.

Use the prefix the ISP hands you. A single static address is a `/32`.
`host-setup.sh` warns if it finds RFC1918 space here under `ext`.

---

## `POSITION=int` — inside the firewall, on a LAN

### `bridge0` takes a DHCP lease

This is the whole difference. Inside the firewall there is no reason to run a
second cable to a management NIC, so `bridge0` gets an address and doubles as
the management path. `dhcp4: true`, and you reach the box at
`http://<hostname>.local:3000/`.

**The trade:** an addressed bridge is not a transparent one. `bridge0` now
answers ARP, appears in the neighbour table, and shows up in its own ntopng
host list. Inside the firewall that is usually the right price for not running
a second cable. Outside it is not — hence two netplan files.

### Reaching it

`WEB_BIND=0.0.0.0` is the expected value here, and `.env.example` says so. Two
reasons, and neither is laziness:

- The DHCP address is not knowable when you write `.env`.
- `bridge0` is `optional: true`, so `systemd-networkd-wait-online` does not
  block boot on it — which means the stack can start *before* the lease lands.
  A pinned address would fail to bind on a cold boot. A wildcard binds
  regardless.

`host-setup.sh` warns, asks for confirmation, and continues. It does not
refuse, the way it does under `ext`. **Change the `admin`/`admin` password at
first login.** A LAN is not a trusted network and this UI can replay every
conversation on the segment it is inline on.

After applying netplan the script waits up to 45 seconds (`DHCP_WAIT`) for the
lease before going on. That wait is not cosmetic: nothing else blocks on the
lease, and the image check a few steps later asks whether a default route
exists. Without the wait, an `int` host with a perfectly good DHCP server gets
told it has no route and must side-load its images by hand.

If you want it pinned instead, make a DHCP reservation and put that address in
`WEB_BIND`. You give up the cold-boot robustness above; the boot unit retries,
so in practice this is survivable.

### mDNS, and the MAC to reserve against

`host-setup.sh` adds `MulticastDNS=yes` to the same networkd drop-in that
already carries `Promiscuous=yes` — netplan has no key for either. That is what
makes `<hostname>.local` resolve to this box. It is deliberately **not** set
for `ext`. If the merge check fails, the script warns and you fall back to the
address, or install `avahi-daemon` as an alternative responder.

If you reserve instead, reserve against **`bridge0`'s own MAC**, which it
inherits from the lowest-numbered member port — not against any address you
would find by looking for a management NIC, because this position does not have
one:

```bash
ip -br link show bridge0
```

The netplan sets `dhcp-identifier: mac`, and that is load-bearing for the
reservation. By default systemd-networkd sends an RFC 4361 client identifier
derived from a DUID, and a DHCP server matching reservations on the hardware
address will not recognise it — the classic "my reservation is ignored on
Ubuntu" symptom.

### Cabling: this bridge will not save you from a loop

STP is off and `forward-delay` is 0, so `bridge0` forwards blindly. It must be
cut **into** a link — switch on one port, the downstream device or segment on
the other. Patch both ports into the same switch and the same VLAN and you have
built a broadcast storm.

STP is off on purpose: a sensor that participates in the LAN's spanning tree
can have one of its ports blocked, which severs the very link it is inline on.
The bridge is meant to be invisible to the topology, not a participant in it.

### Applying netplan may cut your own session

At this position `bridge0` is both the monitored bridge and the host's
management path. If you are running `host-setup.sh` over SSH, you are connected
*through* the interface it is about to tear down and re-lease. The TCP session
will not survive it.

Run it from the console, or be ready to reconnect and rerun — the script is
idempotent and picks up where it stopped. It warns and asks before this step.

### `LOCAL_NETS` is your LAN, all of it

The inverse of the `ext` trap. This is the pre-NAT side, so RFC1918 is exactly
what you will see. List every internal subnet that can appear on this wire,
including VLANs trunked across it, or those hosts land in Remote Hosts and
their names never resolve.

```
LOCAL_NETS=192.168.1.0/24,192.168.20.0/24,10.10.0.0/16
```

`host-setup.sh` warns if it finds no RFC1918 space here under `int`.

### Sizing

An `int` sensor typically sees **more** hosts and more short-lived flows than
an `ext` one, because it sees pre-NAT internal chatter — broadcast, mDNS, SMB,
backup traffic — that never crosses the firewall. If you retune, `MAX_HOSTS` is
usually the one that binds first. Size from a week of real traffic, not from
this paragraph.

---

## No flow history

At either position. There is no ClickHouse service and no `--dump-flows`,
because ntopng's flow export is licensed, not merely optional.
`--dump-flows=clickhouse` — along with the cluster and cloud variants and the
Kafka target — is an **Enterprise M/L/XL/XXL** feature. With no
`/etc/ntopng.license` the daemon says so and carries on regardless:

```
[LICENSE] No license file found /etc/ntopng.license: reading license from redis
[LICENSE] ntopng will start in community mode. You can buy a license at http://shop.ntop.org
...
WARNING: -F clickhouse is available only on Enterprise
```

That is the trap: ntopng starts, looks healthy, and silently exports nothing. A
ClickHouse container here would reserve 8 GB to receive data that never comes.
Community mode still gives you live flows, the host table, alerting, traffic
profiles and the whole UI — only *historical* flow storage is missing.

If you buy a licence: mount it at `/etc/ntopng.license` read-only, restore the
`clickhouse` service, add `--dump-flows` back, and add `--fail-invalid-license`
so an expired licence stops the container instead of quietly downgrading it.

Note also that the image must be `ntop/ntopng:latest`. `:stable` does not exist
— only `latest` is published — and `ntop/ntopng.dev:latest` is the development
build, which ships no `clickhouse-client` binary at all.

### On arm64

That upstream image is **amd64-only**. Both ntop repos publish one tag carrying
a single-arch amd64 manifest, so on an SBC sensor `compose up` fails with:

```
image with reference ntop/ntopng:latest was found but does not provide the
specified platform (linux/arm64)
```

ntop does publish official arm64 *packages*, in the Raspberry Pi apt repos, so
`host-setup.sh` builds them into a local image using `Dockerfile.arm64` and
writes the resulting tag into `.env` as `NTOPNG_IMAGE`. `compose.yaml` reads
`${NTOPNG_IMAGE:-ntop/ntopng:latest}` and knows nothing else about
architecture — unset means amd64 and the upstream image.

The first build takes several minutes on a small board; reruns are cached.
Delete the `NTOPNG_IMAGE` line from `.env` to force a rebuild. To pin a
specific build so two sensors provably match:

```bash
docker build -f Dockerfile.arm64 \
    --build-arg NTOPNG_VERSION=6.7.260805-28837 -t ntopng-arm64:6.7 .
```

Emulation is not an option worth taking: `platform: linux/amd64` plus
`qemu-user-static` will start, but emulating a packet-capture hot path drops
frames, which is the one thing this box exists not to do.

**Size the box before you trust it.** The shipped `.env` is ntop's *large*
tier and assumes a 32 GB host; a 4 GB / 4-core SBC is their *medium* tier and
needs `MAX_FLOWS=200000`, `MAX_HOSTS=25000`, `NTOPNG_MEM=2g`, `REDIS_MEM=768m`,
`REDIS_MAXMEM=384mb`. `host-setup.sh` compares the ceilings against `MemTotal`
and warns, because the alternative failure is ntopng starting fine and being
OOM-killed hours later once the flow table fills. Their sizing table:
<https://www.ntop.org/guides/ntopng/performances/hardware_sizing.html>

One caveat that table does not carry: its core counts are not benchmarked
against in-order low-power cores. nDPI on four Cortex-A53s delivers well under
what four x86 cores do, so treat the medium row as an upper bound on an SBC.

## Order matters

Host networking first, then sysctls, then containers. Bringing the stack up
before the bridge is promiscuous produces a working ntopng that sees almost
nothing, which is a confusing failure to debug. `host-setup.sh` enforces the
order; the steps below are what it does, for when you want to do one by hand.

### 1. Bridge (netplan)

The file for your position → `/etc/netplan/10-ntopng-bridge.yaml`, mode 600.
Offloads off on the physical ports, `optional: true` so
`systemd-networkd-wait-online` doesn't stall boot. Addresses on `bridge0` only
under `int`.

Only ever install **one** of the two. If you are upgrading from the old
`outside-fw` package, retire its file — see "Migrating" below.

### 2. Promiscuous mode (networkd drop-in)

Netplan has no key for this. Confirm the generated filename first — the script
does this by globbing rather than assuming:

```bash
ls /run/systemd/network/                 # expect 10-netplan-bridge0.network
sudo mkdir -p /etc/systemd/network/10-netplan-bridge0.network.d
sudo tee /etc/systemd/network/10-netplan-bridge0.network.d/promisc.conf <<'EOF'
[Link]
Promiscuous=yes
EOF
```

For `POSITION=int`, append the mDNS responder to the same file:

```
[Network]
MulticastDNS=yes
```

The directory name must match the generated unit exactly — a near miss is
ignored in silence. Verify the merge rather than trusting it:

```bash
systemd-analyze cat-config systemd/network/10-netplan-bridge0.network | grep -E 'Promiscuous|MulticastDNS'
```

Requires systemd 249+.

### 3. Host sysctls

```bash
echo br_netfilter | sudo tee /etc/modules-load.d/br_netfilter.conf
sudo modprobe br_netfilter          # before sysctl: the keys don't exist until it loads
sudo cp host/*.conf /etc/sysctl.d/
sudo sysctl --system

sudo ethtool -G enp1s0 rx 4096      # check current: ethtool -g enp1s0
sudo ethtool -G enp2s0 rx 4096
```

`99-transparent-bridge.conf` is not optional on a Docker host, at either
position. Without it, the bridge stops forwarding the moment Docker loads
`br_netfilter`.

### 4. Stack

```bash
cp .env.example .env && chmod 600 .env
docker compose up -d
```

### 5. Boot

`host/ntopng-tap.service` → `/etc/systemd/system/`, enabled. It runs
`docker compose up -d` at boot instead of leaving it to docker's restart
policy, because that policy does not honour `depends_on` — a plain reboot would
bring ntopng back without re-running `netprep`, losing the backstop that forces
the bridge master promiscuous at exactly the moment you would want it.

## Verify

```bash
ip -d link show bridge0 | grep -i promisc          # PROMISC present
ethtool -k enp1s0 | grep -E 'generic-receive|large-receive|tcp-segmentation'
ethtool -k enp2s0 | grep -E 'generic-receive|large-receive|tcp-segmentation'
sysctl net.bridge.bridge-nf-call-iptables          # 0
docker compose ps
docker compose logs ntopng | grep -iE 'bridge0|error|too many'
```

Under `POSITION=int`, also:

```bash
ip -4 -br addr show bridge0                        # a lease, not blank
ping <hostname>.local                              # from another machine
```

`host-setup.sh` runs all of this itself and treats the promiscuous and
bridge-netfilter checks as hard gates. The lease check is a warning: ntopng
captures perfectly well on an addressless bridge, so a missing lease means an
unreachable sensor, not a blind one.

If ntopng starts cleanly but flow counts stay near zero while the bridge is
clearly passing traffic, promiscuous mode on `bridge0` is the first thing to
check — a Linux bridge master only passes forwarded frames up to AF_PACKET taps
when the master itself is promiscuous.

## Memory budget

| Service | Ceiling | The knob that actually spends it |
|---|---|---|
| ntopng | 12 GB | `MAX_FLOWS`, `MAX_HOSTS` |
| redis | 4 GB | `REDIS_MAXMEM` = 2 GB (hard failure, not eviction) |
| unallocated | ~16 GB | kernel and NIC buffers |

Leave the ~16 GB alone. On a capture host, memory handed to a process is memory
the kernel cannot use to absorb a burst.

Redis holds 2 GB under a 4 GB ceiling, not 3 GB. An RDB snapshot forks, and
copy-on-write can transiently push RSS toward twice the dataset; with
`memswap_limit == mem_limit` there is no swap to absorb it, so 3-under-4 was a
cgroup OOM kill mid-snapshot — which under `noeviction` is exactly the config
and alert-state loss the policy exists to prevent. Keep the 2x ratio if you
retune. `98-capture-tuning.conf` sets `vm.overcommit_memory = 1`, which redis
needs for that fork to succeed.

Size from evidence after a week of real traffic:

```bash
docker stats --no-stream
docker compose exec redis redis-cli info memory | grep used_memory_human
```

ntopng's System → Health page reports flow/host table occupancy, which tells you
more about whether the caps are right than RSS does.

## Migrating from the `outside-fw` package

This package replaces the two-folder `lan-monitor/` + `outside-fw/` layout.
For an existing ext sensor:

1. Copy this package over the old one.
2. Add `POSITION=ext` to the existing `.env`. Nothing else in it changes.
3. Rerun `./host-setup.sh`.

The bridge netplan is now installed as `/etc/netplan/10-ntopng-bridge.yaml`
rather than `10-outside-firewall-bridge.yaml`. `host-setup.sh` retires the old
file on sight, renaming it to a `.bak` that netplan does not glob. Leaving both
in place would define `bridge0` twice — which netplan resolves by *merge*, not
by error, so the symptom would be a config that silently does not describe the
running system.

The boot unit keeps its name, `ntopng-tap.service`, so the existing enabled
unit is updated in place rather than orphaned. Its `WorkingDirectory` is
rewritten to wherever you put this package.

## Known rough edges

- Netplan's segmentation-offload keys don't always apply
  ([LP #1979704](https://bugs.launchpad.net/bugs/1979704)). Check `ethtool -k`
  rather than assuming. The `netprep` service covers this; delete it only after
  verifying the netplan path works.
- Netplan writes offload settings to a `.link` file applied by udev at device
  add. `netplan apply` alone often won't re-trigger it —
  `udevadm trigger --action=add /sys/class/net/enp1s0` or reboot.
  `host-setup.sh` does this for every port in `BRIDGE_PORTS`.
- Netplan has no `rxvlan` key. Usually harmless, since modern libpcap
  reconstructs the tag from skb metadata. Check before chasing it.
- `ethtool -G` fails on some NICs (virtio, a few Intel parts). `host-setup.sh`
  warns and continues at whatever the driver allows.
- ntopng defaults to `admin` / `admin` on first login. Change it before you
  bind anything but loopback — which, under `int`, you are doing by default.
- Under `int`, `bridge0` appears in its own ntopng host list. That is not a
  bug; it is the cost of an addressed bridge.
- A SPAN / mirror-port deployment is **not** supported here. It is a different
  design, not a third value of `POSITION`: no bridge, no forwarding, and the
  promiscuous check, `netprep` and the whole `br_netfilter` story would all
  need to change.
