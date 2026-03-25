"""Shared fixtures for the BACnet simulator test suite."""

from __future__ import annotations

from typing import TYPE_CHECKING
from typing import Any

import pytest
import yaml

from bacnet_sim.types import DeviceNetConfig
from bacnet_sim.types import DeviceProfile
from bacnet_sim.types import ObjectDefinition
from bacnet_sim.types import RealismConfig
from bacnet_sim.types import SegmentationSupport

if TYPE_CHECKING:
    from pathlib import Path


@pytest.fixture
def tmp_profiles(tmp_path: Path) -> Path:
    """Create a minimal profiles directory with _base.yaml and vendors.yaml."""
    base: dict[str, Any] = {
        "device": {
            "vendor": "Generic",
            "vendor_name": "Generic BACnet Device",
            "model_name": "Simulator",
            "firmware_revision": "1.0",
            "application_software_version": "1.0.0",
            "protocol_revision": 22,
        },
        "network": {
            "max_apdu": 1476,
            "segmentation": "segmentedBoth",
        },
        "objects": [],
    }
    vendors: dict[str, Any] = {"vendors": {"Generic": 0, "MIELE": 218}}

    (tmp_path / "_base.yaml").write_text(yaml.dump(base))
    (tmp_path / "vendors.yaml").write_text(yaml.dump(vendors))
    return tmp_path


def make_profile(
    *,
    model_name: str = "TestDevice",
    vendor: str = "Generic",
    vendor_id: int = 0,
    max_apdu: int = 1476,
    segmentation: SegmentationSupport = SegmentationSupport.SEGMENTED_BOTH,
    realism: RealismConfig | None = None,
    objects: tuple[ObjectDefinition, ...] = (),
) -> DeviceProfile:
    """Build a DeviceProfile with sensible defaults for testing."""
    return DeviceProfile(
        vendor=vendor,
        vendor_id=vendor_id,
        vendor_name=vendor,
        model_name=model_name,
        firmware_revision="1.0",
        application_software_version="1.0.0",
        protocol_revision=22,
        network=DeviceNetConfig(
            max_apdu=max_apdu,
            segmentation=segmentation,
        ),
        realism=realism or RealismConfig(),
        objects=objects,
    )
