# Test bench

The test bench runs on one Linux host. It contains a real ChirpStack v4
network server in Docker, and an impaired network link between the gateway
side and the server side.

```
 namespace dls-gw          namespace dls-wan (router)        root namespace
 +--------------+          +------------------------+        +----------------+
 | gw0          |==========| wan-gw        wan-srv  |========| dls-srv0       |
 | 10.10.1.2/24 |          | 10.10.1.1     10.10.2.1|        | 10.10.2.2/24   |
 +--------------+          +------------------------+        +----------------+
  gateway simulator         netem delay and loss on           ChirpStack
  and capture point         the egress of both sides          (UDP 1700)
```

The delay D and the loss L apply one time in each direction. A round trip
has a delay of 2 x D. The interface `gw0` has no impairment, so a capture
timestamp on `gw0` is the time at which the gateway sends or receives a
datagram.

The four interfaces have permanent neighbour entries. Without them, the
hosts use ARP, and the ARP messages cross the delayed link: the first
datagram after an address resolution then has an extra delay of 2 x D
(measured: 400 ms and not 200 ms for D = 100 ms). With permanent entries,
no ARP exchange occurs during an experiment.

## Requirements

- Linux with root rights, `iproute2`, the `sch_netem` kernel module and
  `veth` support. `netns.sh up` checks this and stops with a message if
  something is missing.
- Docker Engine with the Compose plugin. The user is in the `docker` group.
- Python 3.11 or later, for `probe.py` and `provision.py`.
- `openssl` and `curl`.

Tested on Debian 13 in an LXC container on Proxmox VE (kernel 7.0).

## Files

| File | Function |
|---|---|
| `netns.sh` | creates the three namespaces and applies `netem` |
| `bench.sh` | starts and stops the ChirpStack containers |
| `probe.py` | sends a Semtech `PULL_DATA` packet and waits for `PULL_ACK` |
| `provision.py` | creates the application, device profile, gateway and devices |
| `chirpstack/` | Docker Compose file and configuration, see `chirpstack/UPSTREAM.md` |

Files that the scripts create, and that are not in the repository:
`chirpstack/.env` (API secret), `.api_key` (API key), `devices.csv`
(device session keys).

## Procedure

Do the steps in this order. The network must exist before ChirpStack
starts, because the gateway bridge listens on the bench address only.

```sh
# 1. Network: create it, then check the delay with ping.
sudo bench/netns.sh up --delay 100
sudo bench/netns.sh verify          # expected: round trip 200 ms, PASS
sudo bench/netns.sh set --delay 0

# 2. ChirpStack.
bench/bench.sh up                   # expected: "ready"
bench/bench.sh versions             # exact image digests

# 3. Check that the gateway bridge receives traffic from the gateway side.
sudo bench/netns.sh exec python3 "$PWD/bench/probe.py" --stat
                                    # expected: PULL_DATA: OK, PUSH_DATA: OK

# 4. Create the bench objects in ChirpStack.
python3 -m venv bench/.venv
bench/.venv/bin/pip install -r bench/requirements.lock
bench/bench.sh apikey
bench/.venv/bin/python bench/provision.py --devices 1
```

To stop:

```sh
bench/bench.sh down                 # keeps the ChirpStack data
sudo bench/netns.sh down
```

`make bench-up` and `make bench-down` do steps 1 and 2, and the stop.

## Web interface

The web interface listens on `127.0.0.1:8080` of the bench host only. From
another computer, open an SSH tunnel:

```sh
ssh -L 8080:127.0.0.1:8080 <user>@<bench-host>
```

Then open `http://127.0.0.1:8080`. The first login is `admin` / `admin`.
Change this password immediately.

## Loss setting

`--loss L` drops each packet with probability L in each direction. For an
exchange that needs one packet in each direction, the success probability
is (1 - L)^2.
