"""Tests for bacnet_sim.types — enums, dataclasses, and parsing."""

from __future__ import annotations

import pytest

from bacnet_sim.types import DeviceNetConfig
from bacnet_sim.types import ObjectDefinition
from bacnet_sim.types import RealismConfig
from bacnet_sim.types import SegmentationSupport


class TestSegmentationSupport:
    def test_values(self) -> None:
        assert SegmentationSupport.SEGMENTED_BOTH == 0
        assert SegmentationSupport.NO_SEGMENTATION == 3

    def test_int_cast(self) -> None:
        assert int(SegmentationSupport.SEGMENTED_TRANSMIT) == 1


class TestRealismConfig:
    def test_defaults(self) -> None:
        rc = RealismConfig()
        assert rc.response_delay_ms == 0.0
        assert rc.response_jitter_ms == 0.0
        assert rc.tsm_pool_size == 0
        assert rc.abort_reason == 0

    def test_frozen(self) -> None:
        rc = RealismConfig()
        with pytest.raises(AttributeError):
            rc.abort_reason = 2  # type: ignore[misc]


class TestObjectDefinition:
    def test_defaults(self) -> None:
        od = ObjectDefinition(object_type="AnalogInput", instance=1, name="temp")
        assert od.units is None
        assert od.default is None
        assert od.states is None

    def test_full_construction(self) -> None:
        od = ObjectDefinition(
            object_type="MultiStateValue",
            instance=5,
            name="mode",
            default=2,
            states=("off", "on", "auto"),
        )
        assert od.states == ("off", "on", "auto")


class TestDeviceNetConfig:
    def test_construction(self) -> None:
        dnc = DeviceNetConfig(
            max_apdu=480,
            segmentation=SegmentationSupport.NO_SEGMENTATION,
        )
        assert dnc.max_apdu == 480
        assert dnc.segmentation == SegmentationSupport.NO_SEGMENTATION
