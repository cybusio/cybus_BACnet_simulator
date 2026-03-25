"""Tests for bacnet_sim.devices — VirtualDevice and DeviceManager."""

from __future__ import annotations

from typing import TYPE_CHECKING
from typing import Any

if TYPE_CHECKING:
    from pathlib import Path

import yaml

from bacnet_sim.devices import DeviceManager
from bacnet_sim.devices import VirtualDevice
from bacnet_sim.profiles import ProfileLoader

from .conftest import make_profile


class TestVirtualDevice:
    def test_construction(self) -> None:
        profile = make_profile(model_name="Test")
        vd = VirtualDevice(device_id=100, profile=profile)
        assert vd.device_id == 100
        assert vd.profile.model_name == "Test"

    def test_mutable(self) -> None:
        profile = make_profile()
        vd = VirtualDevice(device_id=1, profile=profile)
        vd.device_id = 2
        assert vd.device_id == 2


class TestDeviceManager:
    def test_empty(self) -> None:
        mgr = DeviceManager()
        assert len(mgr) == 0
        assert list(mgr.broadcast()) == []

    def test_load_from_profiles(self, tmp_profiles: Path) -> None:
        data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic", "model_name": "DevA"},
        }
        (tmp_profiles / "dev.yaml").write_text(yaml.dump(data))

        loader = ProfileLoader(tmp_profiles)
        mgr = DeviceManager()
        mgr.load_from_profiles(loader, base_device_id=500)

        assert len(mgr) == 1
        devices = list(mgr.broadcast())
        assert devices[0].device_id == 500
        assert devices[0].profile.model_name == "DevA"

    def test_sequential_ids(self, tmp_profiles: Path) -> None:
        for name in ("a.yaml", "b.yaml", "c.yaml"):
            data: dict[str, Any] = {
                "extends": "_base.yaml",
                "device": {"vendor": "Generic", "model_name": name[0]},
            }
            (tmp_profiles / name).write_text(yaml.dump(data))

        loader = ProfileLoader(tmp_profiles)
        mgr = DeviceManager()
        mgr.load_from_profiles(loader, base_device_id=1000)

        assert len(mgr) == 3
        ids = [d.device_id for d in mgr.broadcast()]
        assert ids == [1000, 1001, 1002]

    def test_load_clears_previous(self, tmp_profiles: Path) -> None:
        data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
        }
        (tmp_profiles / "dev.yaml").write_text(yaml.dump(data))
        loader = ProfileLoader(tmp_profiles)

        mgr = DeviceManager()
        mgr.load_from_profiles(loader, base_device_id=100)
        assert len(mgr) == 1

        mgr.load_from_profiles(loader, base_device_id=200)
        assert len(mgr) == 1
        assert next(iter(mgr.broadcast())).device_id == 200
