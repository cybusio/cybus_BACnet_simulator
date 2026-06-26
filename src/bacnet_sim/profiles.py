"""Profile loader with YAML merging and validation."""

from __future__ import annotations

from typing import TYPE_CHECKING
from typing import Any

import yaml

if TYPE_CHECKING:
    from pathlib import Path

from bacnet_sim.types import DeviceNetConfig
from bacnet_sim.types import DeviceProfile
from bacnet_sim.types import DriveSpec
from bacnet_sim.types import ObjectDefinition
from bacnet_sim.types import RealismConfig
from bacnet_sim.types import SegmentationSupport

_SEGMENTATION_MAP: dict[str, SegmentationSupport] = {
    "segmentedBoth": SegmentationSupport.SEGMENTED_BOTH,
    "segmentedTransmit": SegmentationSupport.SEGMENTED_TRANSMIT,
    "segmentedReceive": SegmentationSupport.SEGMENTED_RECEIVE,
    "noSegmentation": SegmentationSupport.NO_SEGMENTATION,
}

_RESERVED_FILES: frozenset[str] = frozenset({"_base.yaml", "vendors.yaml"})


class ProfileValidationError(Exception):
    """Raised when a device profile fails validation."""


_VALID_DRIVE_SHAPES: frozenset[str] = frozenset({"sawtooth", "sine", "toggle"})


def _parse_drive(raw: dict[str, Any] | None) -> DriveSpec | None:
    """Parse the optional `drive:` block on an object definition.

    Returns None when unset. Validates shape against known patterns.
    """
    if not raw:
        return None
    shape = str(raw.get("shape", "sawtooth")).lower()
    if shape not in _VALID_DRIVE_SHAPES:
        msg = f"unknown drive.shape: {shape!r}"
        raise ProfileValidationError(msg)
    return DriveSpec(
        shape=shape,
        period_ms=int(raw.get("period_ms", 500)),
        low=float(raw.get("low", 0.0)),
        high=float(raw.get("high", 100.0)),
        step=float(raw.get("step", 1.0)),
    )


# ---------------------------------------------------------------------------
# Object padding — data-driven generator for scaling device object counts
# ---------------------------------------------------------------------------

_Fields = tuple[tuple[str, str, float], ...]
_Factor = tuple[float, float, int, int]  # base, range, mult, mod
_Phase = tuple[_Fields, str, int, int | None, _Factor]


def _gen_padding(
    phases: tuple[_Phase, ...],
    object_type: str,
    count: int,
    start: int,
) -> tuple[ObjectDefinition, ...]:
    """Generate padding objects from phase definitions.

    Each phase is (fields, prefix, counter_start, counter_max, factor_params).
    counter_max=None means repeat until count is reached.
    """
    objs: list[ObjectDefinition] = []
    inst = start
    for fields, prefix, c_start, c_max, (fb, fr, fm, fmod) in phases:
        counter = c_start
        limit = c_max if c_max is not None else 999_999
        while counter <= limit and len(objs) < count:
            for idx, (suffix, units, base) in enumerate(fields):
                if len(objs) >= count:
                    return tuple(objs)
                factor = fb + fr * ((counter * fm + idx) % fmod) / fmod
                objs.append(
                    ObjectDefinition(
                        object_type=object_type,
                        instance=inst,
                        name=f"{prefix}_{counter}_{suffix}",
                        units=units,
                        default=round(base * factor, 2),
                    )
                )
                inst += 1
            counter += 1
    return tuple(objs[:count])


def _state_padding(spec: dict[str, Any] | None) -> tuple[ObjectDefinition, ...]:
    """One Multi-state Value with `count` states — a large state-text array."""
    if not spec:
        return ()
    count = int(spec.get("count", 0))
    if count <= 0:
        return ()
    return (
        ObjectDefinition(
            object_type="MultiStateValue",
            instance=int(spec.get("instance", 1)),
            name=str(spec.get("name", "bigarray-states")),
            states=tuple(f"s{i}" for i in range(1, count + 1)),
            default=1,
        ),
    )


# --- Harmonics first-phase for energy_meter (structurally unique) ---

_HARMONIC_FIELDS: _Fields = tuple(
    item
    for order in range(7, 64, 2)
    for phase, v_off, i_off in [
        ("L1", 0.0, 0.0),
        ("L2", 0.05, 0.1),
        ("L3", -0.03, -0.05),
    ]
    for item in [
        (
            f"{order}th_voltage_{phase}",
            "percent",
            round(max(0.01, 2.5 * (5.0 / order) ** 1.3 + v_off), 2),
        ),
        (
            f"{order}th_current_{phase}",
            "percent",
            round(max(0.01, 7.0 * (5.0 / order) ** 1.0 + i_off), 2),
        ),
    ]
)

# --- Template definitions ---

_TEMPLATES: dict[str, tuple[str, tuple[_Phase, ...]]] = {
    "energy_meter": (
        "AnalogInput",
        (
            # Phase 1: harmonics (single pass dumps pre-computed fields, factor=1.0)
            (_HARMONIC_FIELDS, "harmonic", 1, 1, (1.0, 0.0, 0, 1)),
            # Phase 2: per-panel sub-meters (overflow)
            (
                (
                    ("voltage_avg", "volts", 230.0),
                    ("current_L1", "amperes", 12.0),
                    ("current_L2", "amperes", 11.5),
                    ("current_L3", "amperes", 12.3),
                    ("active_power", "watts", 7800.0),
                    ("power_factor", "noUnits", 0.95),
                    ("energy_kwh", "kilowattHours", 15000.0),
                    ("demand_kw", "kilowatts", 6.5),
                ),
                "panel",
                1,
                None,
                (0.7, 0.6, 7, 17),
            ),
        ),
    ),
    "district_heating": (
        "AnalogInput",
        (
            # Phase 1: heating circuits
            (
                (
                    ("supply_temp", "degreesCelsius", 50.0),
                    ("return_temp", "degreesCelsius", 35.0),
                    ("flow_rate", "litersPerSecond", 0.30),
                    ("pump_speed", "percent", 60.0),
                    ("valve_pos", "percent", 55.0),
                    ("heat_kw", "kilowatts", 18.0),
                ),
                "circuit",
                3,
                19,
                (0.7, 0.5, 3, 11),
            ),
            # Phase 2: apartment zones (overflow)
            (
                (
                    ("room_temp", "degreesCelsius", 21.5),
                    ("setpoint", "degreesCelsius", 21.0),
                    ("valve", "percent", 45.0),
                    ("energy_kwh", "kilowattHours", 3200.0),
                ),
                "apt",
                1,
                None,
                (0.85, 0.3, 5, 13),
            ),
        ),
    ),
    "hvac_controller": (
        "AnalogInput",
        (
            (
                (
                    ("temp", "degreesCelsius", 22.0),
                    ("setpoint", "degreesCelsius", 22.0),
                    ("damper", "percent", 50.0),
                    ("airflow", "noUnits", 120.0),
                    ("reheat", "percent", 0.0),
                ),
                "vav",
                1,
                None,
                (0.85, 0.3, 3, 11),
            ),
        ),
    ),
    "lift_controller": (
        "AnalogValue",
        (
            # Phase 1: per-floor sensors
            (
                (
                    ("position_mm", "noUnits", 0.0),
                    ("door_zone_sensor", "noUnits", 1.0),
                    ("leveling_precision", "noUnits", 0.0),
                    ("load_at_floor", "noUnits", 0.0),
                    ("wait_time_s", "noUnits", 0.0),
                ),
                "floor",
                1,
                600,
                (0.8, 0.4, 3, 13),
            ),
            # Phase 2: drive/shaft telemetry (overflow)
            (
                (
                    ("motor_current_L1", "amperes", 45.0),
                    ("motor_current_L2", "amperes", 44.5),
                    ("motor_current_L3", "amperes", 45.2),
                    ("rope_tension", "noUnits", 850.0),
                    ("vibration", "noUnits", 0.12),
                    ("bearing_temp", "degreesCelsius", 42.0),
                ),
                "drive",
                1,
                None,
                (0.85, 0.3, 5, 11),
            ),
        ),
    ),
}


def _generate_padding(
    template: str,
    count: int,
    existing_objects: list[dict[str, Any]],
) -> tuple[ObjectDefinition, ...]:
    """Generate padding objects, starting after the highest existing instance."""
    if template not in _TEMPLATES:
        valid = ", ".join(sorted(_TEMPLATES))
        msg = f"Unknown padding template '{template}' (valid: {valid})"
        raise ProfileValidationError(msg)
    obj_type, phases = _TEMPLATES[template]
    max_inst = max(
        (int(o["instance"]) for o in existing_objects if o.get("object_type") == obj_type),
        default=0,
    )
    return _gen_padding(phases, obj_type, count, max_inst + 1)


class ProfileLoader:
    """Load, merge, validate, and build DeviceProfile instances from YAML."""

    def __init__(self, profiles_dir: Path, *, object_padding_override: int = 0) -> None:
        self._dir = profiles_dir
        self._vendors: dict[str, int] | None = None
        self._base: dict[str, Any] | None = None
        self._padding_override = object_padding_override

    def load_all(self) -> list[DeviceProfile]:
        """Load all *.yaml profiles in the directory, skipping reserved files."""
        profiles: list[DeviceProfile] = []
        for yaml_path in sorted(self._dir.glob("*.yaml")):
            if yaml_path.name in _RESERVED_FILES:
                continue
            raw = self._read_yaml(yaml_path)
            base = self._resolve_base(raw)
            merged = self._merge(base, raw)
            if self._padding_override > 0:
                pad = merged.get("object_padding")
                if pad and "template" in pad:
                    pad["count"] = self._padding_override
            self._validate(merged, yaml_path.name)
            profiles.append(self._build_profile(merged))
        return profiles

    def _resolve_base(self, raw: dict[str, Any]) -> dict[str, Any]:
        """Resolve extends chain: _base → intermediate → ... → parent."""
        extends = raw.get("extends", "_base.yaml")
        if extends == "_base.yaml":
            return self._load_base()
        # Search profiles dir and _parents/ subdirectory for the parent file
        parent_path = self._dir / extends
        if not parent_path.exists():
            parent_path = self._dir / "_parents" / extends
        parent_raw = self._read_yaml(parent_path)
        parent_base = self._resolve_base(parent_raw)
        return self._merge(parent_base, parent_raw)

    def _load_base(self) -> dict[str, Any]:
        if self._base is None:
            self._base = self._read_yaml(self._dir / "_base.yaml")
        return self._base

    def _load_vendors(self) -> dict[str, int]:
        if self._vendors is None:
            raw = self._read_yaml(self._dir / "vendors.yaml")
            self._vendors = {k: int(v) for k, v in raw.get("vendors", {}).items()}
        return self._vendors

    @staticmethod
    def _read_yaml(path: Path) -> dict[str, Any]:
        with path.open(encoding="utf-8") as fh:
            data = yaml.safe_load(fh)
        return data if isinstance(data, dict) else {}

    def _merge(
        self,
        base: dict[str, Any],
        override: dict[str, Any],
    ) -> dict[str, Any]:
        """Deep-merge override onto base; override wins, 'extends' stripped."""
        result: dict[str, Any] = {}
        for key in set(base) | set(override):
            if key == "extends":
                continue
            if key in base and key in override:
                b, o = base[key], override[key]
                if isinstance(b, dict) and isinstance(o, dict):
                    result[key] = self._merge(b, o)
                else:
                    result[key] = o
            elif key in override:
                result[key] = override[key]
            else:
                result[key] = base[key]
        return result

    def _validate(self, data: dict[str, Any], filename: str) -> None:
        device = data.get("device", {})
        network = data.get("network", {})
        objects: list[dict[str, Any]] = data.get("objects", []) or []

        vendor = device.get("vendor", "")
        if vendor not in self._load_vendors():
            msg = f"[{filename}] Unknown vendor '{vendor}'"
            raise ProfileValidationError(msg)

        seg = network.get("segmentation", "segmentedBoth")
        if seg not in _SEGMENTATION_MAP:
            msg = f"[{filename}] Invalid segmentation '{seg}'"
            raise ProfileValidationError(msg)

        seen: set[tuple[str, int]] = set()
        for obj in objects:
            key = (obj.get("object_type", ""), int(obj.get("instance", -1)))
            if key in seen:
                msg = f"[{filename}] Duplicate {key[0]} instance {key[1]}"
                raise ProfileValidationError(msg)
            seen.add(key)

        padding = data.get("object_padding")
        if padding and padding.get("template", "") not in _TEMPLATES:
            valid = ", ".join(sorted(_TEMPLATES))
            msg = (
                f"[{filename}] Unknown padding template"
                f" '{padding.get('template', '')}' (valid: {valid})"
            )
            raise ProfileValidationError(msg)

    def _build_profile(self, data: dict[str, Any]) -> DeviceProfile:
        device = data.get("device", {})
        network = data.get("network", {})
        objects_raw: list[dict[str, Any]] = data.get("objects", []) or []
        realism_raw = data.get("realism", {}) or {}
        sim_raw = data.get("simulator", {}) or {}

        vendors = self._load_vendors()
        vendor_name = device.get("vendor", "Generic")

        seg_str = network.get("segmentation", "segmentedBoth")
        segmentation = _SEGMENTATION_MAP.get(
            seg_str,
            SegmentationSupport.SEGMENTED_BOTH,
        )

        return DeviceProfile(
            vendor=vendor_name,
            vendor_id=vendors.get(vendor_name, 0),
            vendor_name=device.get("vendor_name", vendor_name),
            model_name=device.get("model_name", "Simulator"),
            firmware_revision=str(device.get("firmware_revision", "1.0")),
            application_software_version=str(
                device.get("application_software_version", "1.0.0"),
            ),
            protocol_revision=int(device.get("protocol_revision", 22)),
            network=DeviceNetConfig(
                max_apdu=int(network.get("max_apdu", 1476)),
                segmentation=segmentation,
            ),
            realism=RealismConfig(
                response_delay_ms=float(
                    realism_raw.get("response_delay_ms", 0),
                ),
                response_jitter_ms=float(
                    realism_raw.get("response_jitter_ms", 0),
                ),
                tsm_pool_size=int(realism_raw.get("tsm_pool_size", 0)),
                abort_reason=int(realism_raw.get("abort_reason", 0)),
                force_abort=bool(realism_raw.get("force_abort", False)),
                abort_device_reads=bool(
                    realism_raw.get("abort_device_reads", False),
                ),
                overload_abort=bool(realism_raw.get("overload_abort", False)),
                overload_drop_prob=float(realism_raw.get("overload_drop_prob", 0.0)),
                disable_rpm=bool(realism_raw.get("disable_rpm", False)),
                drift_pct=float(realism_raw.get("drift_pct", 0.02)),
                cov_subscription_limit=int(realism_raw.get("cov_subscription_limit", 0)),
            ),
            objects=self._build_objects(data, objects_raw),
            simulator_port=int(sim_raw["port"]) if "port" in sim_raw else None,
            simulator_device_id=int(sim_raw["device_id"]) if "device_id" in sim_raw else None,
        )

    @staticmethod
    def _build_objects(
        data: dict[str, Any],
        objects_raw: list[dict[str, Any]],
    ) -> tuple[ObjectDefinition, ...]:
        explicit = tuple(
            ObjectDefinition(
                object_type=str(o["object_type"]),
                instance=int(o["instance"]),
                name=str(o["name"]),
                units=o.get("units"),
                default=o.get("default"),
                states=tuple(o["states"]) if o.get("states") else None,
                cov_increment=(
                    float(o["cov_increment"]) if o.get("cov_increment") is not None else None
                ),
                drive=_parse_drive(o.get("drive")),
            )
            for o in objects_raw
        )
        explicit += _state_padding(data.get("state_padding"))
        padding_raw = data.get("object_padding")
        if not padding_raw:
            return explicit
        pad_count = int(padding_raw.get("count", 0))
        if pad_count <= 0:
            return explicit
        template = str(padding_raw["template"])
        padding = _generate_padding(template, pad_count, objects_raw)
        return explicit + padding
