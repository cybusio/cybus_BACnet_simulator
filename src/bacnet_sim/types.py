"""Shared types for the BACnet simulator."""

from __future__ import annotations

from dataclasses import dataclass
from enum import IntEnum


class SegmentationSupport(IntEnum):
    """ASHRAE 135-2020 BACnetSegmentation enumeration."""

    SEGMENTED_BOTH = 0
    SEGMENTED_TRANSMIT = 1
    SEGMENTED_RECEIVE = 2
    NO_SEGMENTATION = 3

    @property
    def bp3_string(self) -> str:
        """Return the bacpypes3 segmentation string for this value.

        Example: SegmentationSupport.SEGMENTED_BOTH -> "segmentedBoth"
        """
        _map: dict[int, str] = {
            0: "segmentedBoth",
            1: "segmentedTransmit",
            2: "segmentedReceive",
            3: "noSegmentation",
        }
        return _map[int(self)]


@dataclass(frozen=True, slots=True)
class RealismConfig:
    """Configurable delays and throttling to simulate real embedded devices."""

    response_delay_ms: float = 0.0
    response_jitter_ms: float = 0.0
    tsm_pool_size: int = 0
    abort_reason: int = 0
    force_abort: bool = False
    abort_device_reads: bool = False
    # When saturated (in_flight >= tsm_pool_size), abort the excess read with
    # abort_reason instead of silently dropping it — models a station whose
    # transaction buffer overflows under concurrent load (CC-3851).
    overload_abort: bool = False
    # Fraction of saturated reads the station drops (no reply -> client timeout)
    # instead of aborting. Real Desigo PXC under overload does both: the CC-3851
    # PM log is ~1:1 bufferOverflow aborts to read timeouts. 0 = abort-only.
    overload_drop_prob: float = 0.0
    disable_rpm: bool = False
    drift_pct: float = 0.02  # ±fraction jitter on analog-input every 5s; 0 = static values
    cov_subscription_limit: int = (
        0  # max concurrent COV subscriptions; 0 = unlimited (models a real B-BC finite COV table)
    )


@dataclass(frozen=True, slots=True)
class DeviceNetConfig:
    """Network configuration for a virtual BACnet device."""

    max_apdu: int
    segmentation: SegmentationSupport


@dataclass(frozen=True, slots=True)
class DriveSpec:
    """Periodic value driver for an object's present-value.

    Three shapes supported:
        sawtooth: linear ramp from `low` to `high` and snap back.
        sine:     sinusoidal between `low` and `high`.
        toggle:   binary flip every `period_ms` (Analog/Binary/MultiState).

    `step` is the per-tick increment for analog shapes; ignored for toggle.
    """

    shape: str
    period_ms: int = 500
    low: float = 0.0
    high: float = 100.0
    step: float = 1.0


@dataclass(frozen=True, slots=True)
class ObjectDefinition:
    """Object definition loaded from a profile YAML file."""

    object_type: str
    instance: int
    name: str
    units: str | None = None
    default: float | int | bool | str | None = None
    states: tuple[str, ...] | None = None
    # COV: minimum present-value delta that triggers a COV notification (analog only).
    cov_increment: float | None = None
    # Optional value driver for COV testing; bacpypes3 fires notifications
    # when presentValue crosses cov_increment from the last reported value.
    drive: DriveSpec | None = None


@dataclass(frozen=True, slots=True)
class DeviceProfile:
    """Complete parsed and validated device profile."""

    vendor: str
    vendor_id: int
    vendor_name: str
    model_name: str
    firmware_revision: str
    application_software_version: str
    protocol_revision: int
    network: DeviceNetConfig
    realism: RealismConfig
    objects: tuple[ObjectDefinition, ...]
    # From profile simulator: block — authoritative for port/device_id
    simulator_port: int | None = None
    simulator_device_id: int | None = None
