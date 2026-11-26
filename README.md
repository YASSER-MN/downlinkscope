# DownlinkScope

Passive measurement of LoRaWAN downlink losses on the Semtech UDP link
between a gateway and a network server.

DownlinkScope captures the UDP traffic (port 1700) between a LoRaWAN gateway
and its network server. It links each confirmed uplink to the downlink order
that the server sends, and each order to the result that the gateway reports.
It then measures how many downlinks the gateway cannot send in time, and why,
when the delay and the loss on the gateway-to-server link increase.

Academic project, course "Administration réseau", M2 GLIA, ISIMA
(Université Clermont Auvergne), 2026-2027.

## Status

| Milestone | Content | State |
|---|---|---|
| v0.1 | Project skeleton, build, tests, CI, `tmst` counter arithmetic | done |
| v0.2 | Test bench: network namespaces with `netem`, ChirpStack v4, provisioning | done |
| J1 | Simulated gateway and devices accepted by ChirpStack, first downlink | planned |
| J2 | Capture, decoding, linking, timing margin, CSV export, validation | planned |
| J3 | Experiments with `tc netem` and report | planned |

## Requirements

Linux (tested on Debian 13), a C11 compiler, GNU Make, `pkg-config`,
`libpcap-dev` and `libssl-dev`. For `make lint`: `clang-format`,
`clang-tidy`, `cppcheck` and `shellcheck`.

```sh
sudo apt install build-essential pkg-config libpcap-dev libssl-dev \
  clang clang-tidy clang-format cppcheck shellcheck
```

## Build and test

```sh
make            # build build/downlinkscope
make test       # build and run the unit tests
make asan       # unit tests with AddressSanitizer and UndefinedBehaviorSanitizer
make lint       # clang-format check, cppcheck, clang-tidy
make help       # list all targets
```

## Repository layout

```
src/            tool sources
include/dls/    public headers
tests/unit/     unit tests (Unity)
bench/          test bench: network, ChirpStack, provisioning (bench/README.md)
third_party/    vendored code, each folder with its licence and version
.github/        continuous integration
```

## Licence

MIT, see `LICENSE`. Third-party code keeps its own licence: Unity (MIT),
see `third_party/unity/`. ChirpStack Docker files (MIT), see
`bench/chirpstack/UPSTREAM.md`.
