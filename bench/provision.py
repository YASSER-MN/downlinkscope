#!/usr/bin/env python3
"""provision.py - create the DownlinkScope bench objects in ChirpStack.

The script creates, through the ChirpStack gRPC API:
  - one application,
  - one device profile (EU868, LoRaWAN 1.0.3, Class A, ABP),
  - one gateway,
  - N devices, each activated in ABP mode with its own session keys.

The device identifiers and keys are written to a CSV file. The gateway
simulator reads the same file, so the two sides always use the same keys.

The script is safe to run again: it reuses the objects and the CSV file
that exist. Use --dry-run to build and print every request without a
connection to a server.

Requirements: pip install -r bench/requirements.txt
"""

import argparse
import csv
import pathlib
import secrets
import sys

import grpc
from chirpstack_api import api, common

BENCH_DIR = pathlib.Path(__file__).resolve().parent
APPLICATION_NAME = "downlinkscope"
PROFILE_NAME = "dls-abp-class-a"
CSV_FIELDS = ["dev_eui", "dev_addr", "nwk_s_key", "app_s_key"]

# Identifier ranges of the bench.
# DevAddr: the 7 most significant bits are the network identifier (NwkID).
# NetID 000000 gives NwkID 0, so every DevAddr of the bench is below 0x02000000.
DEV_EUI_BASE = 0xD15C00000000A000
DEV_ADDR_BASE = 0x00D15000
MAX_DEVICES = 1000


def build_application(tenant_id: str) -> api.CreateApplicationRequest:
    return api.CreateApplicationRequest(
        application=api.Application(
            name=APPLICATION_NAME,
            description="DownlinkScope test bench",
            tenant_id=tenant_id,
        )
    )


def build_device_profile(tenant_id: str, rx1_delay: int) -> api.CreateDeviceProfileRequest:
    return api.CreateDeviceProfileRequest(
        device_profile=api.DeviceProfile(
            name=PROFILE_NAME,
            description="DownlinkScope bench: EU868, LoRaWAN 1.0.3, Class A, ABP",
            tenant_id=tenant_id,
            region=common.Region.EU868,
            mac_version=common.MacVersion.LORAWAN_1_0_3,
            reg_params_revision=common.RegParamsRevision.A,
            adr_algorithm_id="default",
            uplink_interval=3600,
            # 0 = the server sends no device-status request. A status request
            # is a MAC command, and it would add downlinks that the
            # experiment does not control.
            device_status_req_interval=0,
            flush_queue_on_activate=True,
            supports_otaa=False,
            supports_class_b=False,
            supports_class_c=False,
            # ABP settings: the device has these values from the start.
            abp_rx1_delay=rx1_delay,
            abp_rx1_dr_offset=0,
            abp_rx2_dr=0,
            abp_rx2_freq=869525000,
        )
    )


def build_gateway(tenant_id: str, gateway_eui: str) -> api.CreateGatewayRequest:
    return api.CreateGatewayRequest(
        gateway=api.Gateway(
            gateway_id=gateway_eui,
            name="dls-gateway",
            description="DownlinkScope simulated gateway",
            tenant_id=tenant_id,
            stats_interval=30,
        )
    )


def build_device(row: dict, application_id: str, profile_id: str) -> api.CreateDeviceRequest:
    return api.CreateDeviceRequest(
        device=api.Device(
            dev_eui=row["dev_eui"],
            name=f"dls-device-{row['dev_addr']}",
            description="DownlinkScope simulated device",
            application_id=application_id,
            device_profile_id=profile_id,
            # The simulator starts its frame counter at 0 in each run. Without
            # this option, the server refuses a counter that goes back.
            # Acceptable on a closed test bench only.
            skip_fcnt_check=True,
            is_disabled=False,
        )
    )


def build_activation(row: dict) -> api.ActivateDeviceRequest:
    # LoRaWAN 1.0.x has one network session key. ChirpStack stores it in the
    # three network key fields of the 1.1 data model.
    return api.ActivateDeviceRequest(
        device_activation=api.DeviceActivation(
            dev_eui=row["dev_eui"],
            dev_addr=row["dev_addr"],
            app_s_key=row["app_s_key"],
            nwk_s_enc_key=row["nwk_s_key"],
            s_nwk_s_int_key=row["nwk_s_key"],
            f_nwk_s_int_key=row["nwk_s_key"],
            f_cnt_up=0,
            n_f_cnt_down=0,
            a_f_cnt_down=0,
        )
    )


def load_or_create_devices(path: pathlib.Path, count: int) -> list[dict]:
    """Read the device table, and add new devices if the table is too short."""
    rows: list[dict] = []
    if path.exists():
        with path.open(newline="", encoding="ascii") as handle:
            rows = list(csv.DictReader(handle))
        if rows and list(rows[0].keys()) != CSV_FIELDS:
            raise SystemExit(f"error: {path} does not have the columns {CSV_FIELDS}")
    for index in range(len(rows), count):
        rows.append(
            {
                "dev_eui": f"{DEV_EUI_BASE + index:016x}",
                "dev_addr": f"{DEV_ADDR_BASE + index:08x}",
                "nwk_s_key": secrets.token_hex(16),
                "app_s_key": secrets.token_hex(16),
            }
        )
    path.touch(mode=0o600, exist_ok=True)
    path.chmod(0o600)
    with path.open("w", newline="", encoding="ascii") as handle:
        writer = csv.DictWriter(handle, fieldnames=CSV_FIELDS, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)
    return rows[:count]


def exists(call, request, metadata) -> bool:
    """Return True if a Get request finds the object."""
    try:
        call(request, metadata=metadata)
        return True
    except grpc.RpcError as exc:
        if exc.code() == grpc.StatusCode.NOT_FOUND:
            return False
        raise


def find_by_name(items, name: str):
    return next((item.id for item in items if item.name == name), None)


def provision(args: argparse.Namespace, devices: list[dict]) -> None:
    token = pathlib.Path(args.api_key_file).read_text(encoding="ascii").strip()
    metadata = [("authorization", f"Bearer {token}")]

    with grpc.insecure_channel(args.server) as channel:
        tenants = api.TenantServiceStub(channel)
        applications = api.ApplicationServiceStub(channel)
        profiles = api.DeviceProfileServiceStub(channel)
        gateways = api.GatewayServiceStub(channel)
        device_service = api.DeviceServiceStub(channel)

        found = tenants.List(api.ListTenantsRequest(limit=100), metadata=metadata).result
        if not found:
            raise SystemExit("error: the server has no tenant")
        tenant_id = find_by_name(found, args.tenant) or found[0].id
        print(f"tenant            {tenant_id}")

        listed = applications.List(
            api.ListApplicationsRequest(limit=100, tenant_id=tenant_id, search=APPLICATION_NAME),
            metadata=metadata,
        ).result
        application_id = find_by_name(listed, APPLICATION_NAME)
        if application_id is None:
            application_id = applications.Create(build_application(tenant_id), metadata=metadata).id
            print(f"application       {application_id} (created)")
        else:
            print(f"application       {application_id} (exists)")

        listed = profiles.List(
            api.ListDeviceProfilesRequest(limit=100, tenant_id=tenant_id, search=PROFILE_NAME),
            metadata=metadata,
        ).result
        profile_id = find_by_name(listed, PROFILE_NAME)
        if profile_id is None:
            request = build_device_profile(tenant_id, args.rx1_delay)
            profile_id = profiles.Create(request, metadata=metadata).id
            print(f"device profile    {profile_id} (created, RX1 delay {args.rx1_delay} s)")
        else:
            print(f"device profile    {profile_id} (exists, not changed)")

        if exists(gateways.Get, api.GetGatewayRequest(gateway_id=args.gateway_eui), metadata):
            print(f"gateway           {args.gateway_eui} (exists)")
        else:
            gateways.Create(build_gateway(tenant_id, args.gateway_eui), metadata=metadata)
            print(f"gateway           {args.gateway_eui} (created)")

        created = 0
        for row in devices:
            if not exists(device_service.Get, api.GetDeviceRequest(dev_eui=row["dev_eui"]), metadata):
                device_service.Create(build_device(row, application_id, profile_id), metadata=metadata)
                created += 1
            # Activate in each run: this resets the frame counters to 0.
            device_service.Activate(build_activation(row), metadata=metadata)
        print(f"devices           {len(devices)} activated in ABP mode ({created} created)")


def dry_run(args: argparse.Namespace, devices: list[dict]) -> None:
    tenant = "00000000-0000-0000-0000-000000000000"
    requests = [
        build_application(tenant),
        build_device_profile(tenant, args.rx1_delay),
        build_gateway(tenant, args.gateway_eui),
        build_device(devices[0], "<application-id>", "<profile-id>"),
        build_activation({**devices[0], "nwk_s_key": "<hidden>", "app_s_key": "<hidden>"}),
    ]
    for request in requests:
        print(f"--- {type(request).__name__}\n{request}", end="")
    print(f"--- dry run: {len(devices)} devices in the table, no request sent")


def hex_string(length: int):
    def check(text: str) -> str:
        value = text.lower()
        if len(value) != length or any(c not in "0123456789abcdef" for c in value):
            raise argparse.ArgumentTypeError(f"must have {length} hexadecimal characters")
        return value

    return check


def main() -> int:
    parser = argparse.ArgumentParser(description="Create the DownlinkScope bench objects in ChirpStack.")
    parser.add_argument("--server", default="127.0.0.1:8080", help="ChirpStack gRPC address (default: 127.0.0.1:8080)")
    parser.add_argument("--api-key-file", default=str(BENCH_DIR / ".api_key"), help="file with the API key")
    parser.add_argument("--tenant", default="ChirpStack", help="tenant name (default: ChirpStack)")
    parser.add_argument("--gateway-eui", type=hex_string(16), default="d15c000000000001", help="gateway EUI")
    parser.add_argument("--devices", type=int, default=1, help="number of devices (default: 1)")
    parser.add_argument("--rx1-delay", type=int, default=1, help="RX1 delay in seconds, 1 to 15 (default: 1)")
    parser.add_argument("--devices-file", default=str(BENCH_DIR / "devices.csv"), help="device table (CSV)")
    parser.add_argument("--dry-run", action="store_true", help="build and print the requests, send nothing")
    args = parser.parse_args()

    if not 1 <= args.devices <= MAX_DEVICES:
        parser.error(f"--devices must be from 1 to {MAX_DEVICES}")
    if not 1 <= args.rx1_delay <= 15:
        parser.error("--rx1-delay must be from 1 to 15")

    devices = load_or_create_devices(pathlib.Path(args.devices_file), args.devices)
    if args.dry_run:
        dry_run(args, devices)
        return 0
    try:
        provision(args, devices)
    except FileNotFoundError:
        print(f"error: no API key file {args.api_key_file}. Run 'bench/bench.sh apikey' first.", file=sys.stderr)
        return 1
    except grpc.RpcError as exc:
        print(f"error: ChirpStack API call failed: {exc.code().name}: {exc.details()}", file=sys.stderr)
        return 1
    print(f"device table      {args.devices_file}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
