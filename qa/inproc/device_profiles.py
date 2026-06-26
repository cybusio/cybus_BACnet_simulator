"""BACnet simulator device profiles — single source of truth for factory tests.

Each profile defines the device's protocol characteristics, expected objects,
timing parameters, and test capabilities. Topic names must match the SCF
endpoint topics exactly (derived from generate-scf.sh output).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

ValueType = Literal["number", "string", "boolean", "object_id", "bitstring"]


@dataclass(frozen=True, slots=True)
class Obj:
    """One BACnet endpoint as it appears on the MQTT bus."""

    topic: str
    value_type: ValueType
    enum: tuple[str, ...] | None = None
    writable: bool = False
    max_silence_override: float | None = None  # overrides Device.max_silence for this endpoint


@dataclass(frozen=True, slots=True)
class Device:
    """Full characterization of one simulator device."""

    name: str
    port: int
    device_id: int
    scf_name: str  # metadata.name in SCF, also scf/<scf_name>.yml
    max_apdu: int
    segmentation: str
    abort_code: int | None  # None = no abort behavior
    rpm_supported: bool
    settle_time: float  # seconds to wait after deploy before expecting data
    max_silence: float  # max seconds between publishes before flagging
    objects: tuple[Obj, ...] = ()
    capabilities: tuple[str, ...] = ()  # which scenarios: read, write, abort, slow, empty


# --- Topic naming convention ---
# CW uses metadata.name as-is for the MQTT topic prefix.
# MQTT topic: services/<scf_name>/<endpoint_topic>
# Example: metadata.name = "modern_controller" -> services/modern_controller/AI1

_BINARY_ENUM: tuple[str, ...] = ("active", "inactive")

ABORT_SEG = Device(
    name="Schneider SmartX (abort 4)",
    port=47817,
    device_id=600002,
    scf_name="abort_segmentation",
    max_apdu=480,
    segmentation="no-segmentation",
    abort_code=4,
    rpm_supported=True,
    settle_time=10,
    max_silence=5,
    capabilities=("read", "abort"),
    objects=(
        Obj("AI1", "number"),
        Obj("AI2", "number"),
        Obj("AI3", "number"),
        Obj("AI4", "number"),
        Obj("AI5", "number"),
        Obj("AO1", "number"),
        Obj("AO2", "number"),
        Obj("BI1", "string", enum=_BINARY_ENUM),
        Obj("BV1", "string", enum=_BINARY_ENUM),
        Obj("BV2", "string", enum=_BINARY_ENUM),
    ),
)

EMPTY = Device(
    name="Generic EmptyDevice",
    port=47819,
    device_id=600004,
    scf_name="empty_device",
    max_apdu=1476,
    segmentation="segmented-both",
    abort_code=None,
    rpm_supported=True,
    settle_time=5,
    max_silence=10,
    capabilities=("empty",),
    objects=(),
)

ENERGY = Device(
    name="GreenEnergy eBmgr",
    port=47809,
    device_id=2000001,
    scf_name="green_energy_ebmgr",
    max_apdu=480,
    segmentation="no-segmentation",
    abort_code=11,
    rpm_supported=True,
    settle_time=30,
    max_silence=10,
    capabilities=("read", "abort"),
    objects=(
        Obj("BV1", "string", enum=_BINARY_ENUM),
        Obj("AV1", "number"),
        Obj("AV2", "number"),
        Obj("AV3", "number"),
        Obj("AV4", "number"),
        Obj("AV5", "number"),
        Obj("AV6", "number"),
        *[Obj(f"AI{i}", "number") for i in range(1, 32)],
        Obj("BI1", "string", enum=_BINARY_ENUM),
        Obj("BI2", "string", enum=_BINARY_ENUM),
        Obj("BI3", "string", enum=_BINARY_ENUM),
        Obj("BI4", "string", enum=_BINARY_ENUM),
        Obj("BI5", "string", enum=_BINARY_ENUM),
        Obj("BI6", "string", enum=_BINARY_ENUM),
    ),
)

LEGACY = Device(
    name="Siemens PXC36",
    port=47810,
    device_id=300001,
    scf_name="legacy_controller",
    max_apdu=206,
    segmentation="no-segmentation",
    abort_code=1,
    rpm_supported=True,
    settle_time=15,
    max_silence=10,
    capabilities=("read", "abort"),
    objects=(
        Obj("AI1", "number"),
        Obj("AI2", "number"),
        Obj("AI3", "number"),
        Obj("AI4", "number"),
        Obj("AI5", "number"),
        Obj("AI6", "number"),
        Obj("AI10", "number"),
        Obj("AI11", "number"),
        Obj("AI12", "number"),
        Obj("AI13", "number"),
        Obj("BI1", "string", enum=_BINARY_ENUM),
        Obj("BI2", "string", enum=_BINARY_ENUM),
        Obj("BI3", "string", enum=_BINARY_ENUM),
        Obj("BI4", "string", enum=_BINARY_ENUM),
    ),
)

_MIELE_OBJECTS: tuple[Obj, ...] = (
    Obj("AV101009", "number"),
    Obj("AV101017", "number"),
    Obj("AV101028", "number"),
    Obj("AV101037", "number"),
    Obj("AV101046", "number"),
    Obj("AV101055", "number"),
    *[Obj(f"AI{i}", "number") for i in range(1, 95)],
    # object-list is polled every 300s (SCF interval 300000ms) — use 310s silence budget
    Obj("object-list", "object_id", max_silence_override=310),
)

MIELE = Device(
    name="Miele EnergyMeter",
    port=47808,
    device_id=1014006,
    scf_name="miele_energy_meter",
    max_apdu=480,
    segmentation="no-segmentation",
    abort_code=1,
    rpm_supported=True,
    settle_time=310,  # must cover the 300s object-list poll interval
    max_silence=25,  # 100 objects via abort fallback → indexed reads create ~22s gaps
    capabilities=("read", "abort"),
    objects=_MIELE_OBJECTS,
)

MODERN = Device(
    name="Trane Tracer SC+",
    port=47811,
    device_id=400001,
    scf_name="modern_controller",
    max_apdu=1476,
    segmentation="segmented-both",
    abort_code=None,
    rpm_supported=True,
    settle_time=5,
    max_silence=3,
    capabilities=("read", "write"),
    objects=(
        Obj("AI1", "number"),
        Obj("AI2", "number"),
        Obj("AI3", "number"),
        Obj("AI4", "number"),
        Obj("AI5", "number"),
        Obj("AI6", "number"),
        Obj("AV1", "number", writable=True),
        Obj("AV2", "number", writable=True),
        Obj("AV3", "number", writable=True),
        Obj("AV4", "number", writable=True),
        Obj("AV5", "number", writable=True),
        Obj("AO1", "number"),
        Obj("AO2", "number"),
        Obj("AO3", "number"),
        Obj("BI1", "string", enum=_BINARY_ENUM),
        Obj("BI2", "string", enum=_BINARY_ENUM),
        Obj("BI3", "string", enum=_BINARY_ENUM),
        Obj("BI4", "string", enum=_BINARY_ENUM),
        Obj("BV1", "string", enum=_BINARY_ENUM),
        Obj("BV2", "string", enum=_BINARY_ENUM),
        Obj("MV1", "number"),
        # NO1 (NotificationClass) omitted — adapter can't read present-value from it
    ),
)

_NEWLIFT_BV_INSTANCES: tuple[int, ...] = (
    2,
    3,
    9,
    10,
    12,
    13,
    14,
    15,
    16,
    18,
    19,
    20,
    21,
    22,
    23,
    24,
    25,
    26,
    27,
    28,
    29,
    30,
    31,
    32,
    33,
    34,
    35,
    36,
    37,
    38,
    39,
    40,
    41,
    42,
    43,
    44,
    45,
    46,
    47,
    48,
    49,
    50,
    51,
    52,
    53,
    54,
    55,
    56,
    57,
    58,
    59,
    60,
    61,
    62,
    63,
    66,
    69,
    70,
    71,
    72,
    74,
    75,
    76,
    77,
    78,
    79,
    80,
    81,
    86,
    87,
    88,
    89,
    90,
    91,
    92,
    93,
    94,
    95,
    96,
    97,
    99,
    100,
    101,
    102,
    103,
    104,
    105,
    106,
    107,
    108,
)

NEWLIFT = Device(
    name="MBS UGW Elevator",
    port=47812,
    device_id=2000,
    scf_name="newlift_gateway",
    max_apdu=1476,
    segmentation="segmented-both",
    abort_code=None,
    rpm_supported=True,
    settle_time=10,
    max_silence=5,
    capabilities=("read",),
    objects=(
        Obj("BI0", "string", enum=_BINARY_ENUM),
        Obj("AV1", "number"),
        Obj("AV4", "number"),
        Obj("AV5", "number"),
        Obj("AV82", "number"),
        Obj("AV83", "number"),
        Obj("AV84", "number"),
        Obj("AV85", "number"),
        *[Obj(f"BV{i}", "string", enum=_BINARY_ENUM) for i in _NEWLIFT_BV_INSTANCES],
        Obj("MV6", "number"),
        Obj("MV7", "number"),
        Obj("MV8", "number"),
        Obj("MV11", "number"),
        Obj("MV17", "number"),
        Obj("MV73", "number"),
        Obj("MO300", "number"),
        Obj("BO303", "string", enum=_BINARY_ENUM),
    ),
)

NO_RPM = Device(
    name="Honeywell XL50 (no RPM)",
    port=47816,
    device_id=600001,
    scf_name="no_rpm_controller",
    max_apdu=480,
    segmentation="no-segmentation",
    abort_code=1,
    rpm_supported=False,
    settle_time=10,
    max_silence=5,
    capabilities=("read", "no_rpm"),
    objects=(
        Obj("AI1", "number"),
        Obj("AI2", "number"),
        Obj("AI3", "number"),
        Obj("AI4", "number"),
        Obj("AO1", "number"),
        Obj("AO2", "number"),
        Obj("BI1", "string", enum=_BINARY_ENUM),
        Obj("BI2", "string", enum=_BINARY_ENUM),
        Obj("BV1", "string", enum=_BINARY_ENUM),
        Obj("BV2", "string", enum=_BINARY_ENUM),
    ),
)

OVERLOADED = Device(
    name="Miele Overloaded",
    port=47813,
    device_id=1014007,
    scf_name="miele_overloaded",
    max_apdu=480,
    segmentation="no-segmentation",
    abort_code=8,
    rpm_supported=True,
    settle_time=300,  # one full cycle of 101 endpoints at ~13 reads/s
    max_silence=180,  # very slow, many timeouts expected
    capabilities=("read", "abort", "slow"),
    objects=_MIELE_OBJECTS,
)

ULTRA_SLOW = Device(
    name="Generic SlowGateway",
    port=47818,
    device_id=600003,
    scf_name="ultra_slow",
    max_apdu=480,
    segmentation="no-segmentation",
    abort_code=None,
    rpm_supported=True,
    settle_time=30,
    max_silence=60,
    capabilities=("read", "slow"),
    objects=(
        Obj("AI1", "number"),
        Obj("AI2", "number"),
        Obj("BI1", "string", enum=_BINARY_ENUM),
        Obj("BV1", "string", enum=_BINARY_ENUM),
    ),
)

# Indexed by key for parametrize
ALL_DEVICES: dict[str, Device] = {
    "abort_seg": ABORT_SEG,
    "empty": EMPTY,
    "energy": ENERGY,
    "legacy": LEGACY,
    "miele": MIELE,
    "modern": MODERN,
    "newlift": NEWLIFT,
    "no_rpm": NO_RPM,
    "overloaded": OVERLOADED,
    "ultra_slow": ULTRA_SLOW,
}


def devices_with(*caps: str) -> list[str]:
    """Return device keys that have ALL given capabilities."""
    return [k for k, d in ALL_DEVICES.items() if all(c in d.capabilities for c in caps)]


def mqtt_prefix(scf_name: str) -> str:
    """CW topic prefix: uses scf_name as-is."""
    return f"services/{scf_name}"
