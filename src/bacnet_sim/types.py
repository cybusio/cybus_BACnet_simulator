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


@dataclass(frozen=True, slots=True)
class DeviceNetConfig:
    """Network configuration for a virtual BACnet device."""

    max_apdu: int
    segmentation: SegmentationSupport


@dataclass(frozen=True, slots=True)
class ObjectDefinition:
    """Object definition loaded from a profile YAML file."""

    object_type: str
    instance: int
    name: str
    units: str | None = None
    default: float | int | bool | str | None = None
    states: tuple[str, ...] | None = None


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
