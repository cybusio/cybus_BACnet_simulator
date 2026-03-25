"""Tests for bacnet_sim.profiles — YAML loading, merging, and validation."""

from __future__ import annotations

from typing import TYPE_CHECKING
from typing import Any

if TYPE_CHECKING:
    from pathlib import Path

import pytest
import yaml

from bacnet_sim.profiles import ProfileLoader
from bacnet_sim.profiles import ProfileValidationError
from bacnet_sim.types import SegmentationSupport


class TestProfileLoaderMerge:
    def test_override_scalar(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic", "model_name": "OverrideTest"},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles) == 1
        assert profiles[0].model_name == "OverrideTest"

    def test_override_nested_dict(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "network": {"max_apdu": 480, "segmentation": "noSegmentation"},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert profiles[0].network.max_apdu == 480
        assert profiles[0].network.segmentation == SegmentationSupport.NO_SEGMENTATION

    def test_extends_key_stripped(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        loader = ProfileLoader(tmp_profiles)
        base = loader._load_base()
        merged = loader._merge(base, profile_data)
        assert "extends" not in merged


class TestProfileLoaderValidation:
    def test_unknown_vendor_raises(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "UnknownCorp"},
        }
        (tmp_profiles / "bad.yaml").write_text(yaml.dump(profile_data))
        with pytest.raises(ProfileValidationError, match="Unknown vendor"):
            ProfileLoader(tmp_profiles).load_all()

    def test_invalid_segmentation_raises(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "network": {"segmentation": "totallyBogus"},
        }
        (tmp_profiles / "bad.yaml").write_text(yaml.dump(profile_data))
        with pytest.raises(ProfileValidationError, match="Invalid segmentation"):
            ProfileLoader(tmp_profiles).load_all()

    def test_duplicate_object_instance_raises(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {"object_type": "AnalogInput", "instance": 1, "name": "a"},
                {"object_type": "AnalogInput", "instance": 1, "name": "b"},
            ],
        }
        (tmp_profiles / "bad.yaml").write_text(yaml.dump(profile_data))
        with pytest.raises(ProfileValidationError, match="Duplicate"):
            ProfileLoader(tmp_profiles).load_all()

    def test_same_instance_different_types_ok(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {"object_type": "AnalogInput", "instance": 1, "name": "ai1"},
                {"object_type": "AnalogValue", "instance": 1, "name": "av1"},
            ],
        }
        (tmp_profiles / "ok.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 2


class TestProfileLoaderBuild:
    def test_objects_parsed(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {
                    "object_type": "AnalogValue",
                    "instance": 1,
                    "name": "temp",
                    "units": "degreesCelsius",
                    "default": 22.5,
                },
            ],
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        obj = profiles[0].objects[0]
        assert obj.object_type == "AnalogValue"
        assert obj.instance == 1
        assert obj.units == "degreesCelsius"
        assert obj.default == 22.5

    def test_realism_config_parsed(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "realism": {
                "response_delay_ms": 25,
                "response_jitter_ms": 15,
                "tsm_pool_size": 12,
                "abort_reason": 11,
            },
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        r = profiles[0].realism
        assert r.response_delay_ms == 25.0
        assert r.response_jitter_ms == 15.0
        assert r.tsm_pool_size == 12
        assert r.abort_reason == 11

    def test_vendor_id_resolved(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "MIELE", "vendor_name": "Miele Professional"},
        }
        (tmp_profiles / "miele.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert profiles[0].vendor_id == 218
        assert profiles[0].vendor_name == "Miele Professional"

    def test_skips_reserved_files(self, tmp_profiles: Path) -> None:
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert profiles == []

    def test_multistate_with_states(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {
                    "object_type": "MultiStateValue",
                    "instance": 1,
                    "name": "mode",
                    "default": 1,
                    "states": ["off", "heat", "cool"],
                },
            ],
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        obj = profiles[0].objects[0]
        assert obj.states == ("off", "heat", "cool")


class TestObjectPadding:
    def test_energy_meter_padding(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {
                    "object_type": "AnalogValue",
                    "instance": 1,
                    "name": "power",
                    "units": "watts",
                    "default": 100,
                },
            ],
            "object_padding": {"template": "energy_meter", "count": 10},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 11  # 1 explicit + 10 padded

    def test_district_heating_padding(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "object_padding": {"template": "district_heating", "count": 20},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 20

    def test_hvac_controller_padding(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "object_padding": {"template": "hvac_controller", "count": 15},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 15
        # VAV zones: 5 objects per zone, 3 full zones
        assert profiles[0].objects[0].name == "vav_1_temp"
        assert profiles[0].objects[4].name == "vav_1_reheat"
        assert profiles[0].objects[5].name == "vav_2_temp"

    def test_padding_starts_after_existing_ai(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {"object_type": "AnalogInput", "instance": 50, "name": "ai50"},
            ],
            "object_padding": {"template": "energy_meter", "count": 3},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        padded = [o for o in profiles[0].objects if o.instance > 50]
        assert len(padded) == 3
        assert padded[0].instance == 51

    def test_padding_count_zero_no_effect(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {"object_type": "AnalogValue", "instance": 1, "name": "av1"},
            ],
            "object_padding": {"template": "energy_meter", "count": 0},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 1

    def test_unknown_template_raises(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "object_padding": {"template": "nonexistent", "count": 10},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        with pytest.raises(ProfileValidationError, match="Unknown padding template"):
            ProfileLoader(tmp_profiles).load_all()

    def test_large_count(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "object_padding": {"template": "energy_meter", "count": 500},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 500
        # All should be unique instances
        instances = [o.instance for o in profiles[0].objects]
        assert len(instances) == len(set(instances))

    def test_lift_controller_padding(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "object_padding": {"template": "lift_controller", "count": 20},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 20
        # Generates AnalogValue objects (not AnalogInput)
        assert all(o.object_type == "AnalogValue" for o in profiles[0].objects)
        # Per-floor sensors: 5 per floor
        assert profiles[0].objects[0].name == "floor_1_position_mm"
        assert profiles[0].objects[4].name == "floor_1_wait_time_s"
        assert profiles[0].objects[5].name == "floor_2_position_mm"

    def test_lift_padding_starts_after_existing_av(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {"object_type": "AnalogValue", "instance": 85, "name": "av85"},
            ],
            "object_padding": {"template": "lift_controller", "count": 5},
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        padded = [o for o in profiles[0].objects if o.instance > 85]
        assert len(padded) == 5
        assert padded[0].instance == 86

    def test_no_padding_section(self, tmp_profiles: Path) -> None:
        profile_data: dict[str, Any] = {
            "extends": "_base.yaml",
            "device": {"vendor": "Generic"},
            "objects": [
                {"object_type": "AnalogInput", "instance": 1, "name": "ai1"},
            ],
        }
        (tmp_profiles / "test.yaml").write_text(yaml.dump(profile_data))
        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles[0].objects) == 1


class TestProfileLoaderMultiple:
    def test_loads_multiple_profiles_sorted(self, tmp_profiles: Path) -> None:
        for name in ("zebra.yaml", "alpha.yaml"):
            data: dict[str, Any] = {
                "extends": "_base.yaml",
                "device": {"vendor": "Generic", "model_name": name.removesuffix(".yaml")},
            }
            (tmp_profiles / name).write_text(yaml.dump(data))

        profiles = ProfileLoader(tmp_profiles).load_all()
        assert len(profiles) == 2
        assert profiles[0].model_name == "alpha"
        assert profiles[1].model_name == "zebra"
