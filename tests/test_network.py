"""Tests for bacnet_sim.network — object builders, abort logic, and helpers."""

from __future__ import annotations

import pytest
from bacpypes3.apdu import AbortReason
from bacpypes3.errors import AbortException
from bacpypes3.object import AnalogInputObject
from bacpypes3.object import AnalogValueObject
from bacpypes3.object import BinaryValueObject
from bacpypes3.object import MultiStateValueObject

from bacnet_sim.network import _build_bp3_object
from bacnet_sim.network import _extra_kwargs
from bacnet_sim.network import _make_abort_exception
from bacnet_sim.network import _make_device_object
from bacnet_sim.types import ObjectDefinition
from bacnet_sim.types import RealismConfig
from bacnet_sim.types import SegmentationSupport

from .conftest import make_profile


class TestExtraKwargs:
    def test_analog_input(self) -> None:
        defn = ObjectDefinition(
            object_type="AnalogInput",
            instance=1,
            name="temp",
            units="degreesCelsius",
            default=22.5,
        )
        kw = _extra_kwargs(defn)
        assert kw["presentValue"] == 22.5
        assert kw["units"] == "degreesCelsius"
        assert kw["outOfService"] is False

    def test_analog_value_no_out_of_service(self) -> None:
        defn = ObjectDefinition(
            object_type="AnalogValue", instance=1, name="setpoint", default=21.0
        )
        kw = _extra_kwargs(defn)
        assert kw["presentValue"] == 21.0
        assert "outOfService" not in kw

    def test_binary_active(self) -> None:
        defn = ObjectDefinition(object_type="BinaryValue", instance=1, name="flag", default=True)
        kw = _extra_kwargs(defn)
        assert kw["presentValue"] == "active"

    def test_binary_inactive(self) -> None:
        defn = ObjectDefinition(object_type="BinaryValue", instance=1, name="flag", default=False)
        kw = _extra_kwargs(defn)
        assert kw["presentValue"] == "inactive"

    def test_binary_input_out_of_service(self) -> None:
        defn = ObjectDefinition(object_type="BinaryInput", instance=1, name="di", default=True)
        kw = _extra_kwargs(defn)
        assert kw["outOfService"] is False

    def test_multistate_with_states(self) -> None:
        defn = ObjectDefinition(
            object_type="MultiStateValue",
            instance=1,
            name="mode",
            default=2,
            states=("off", "on", "auto"),
        )
        kw = _extra_kwargs(defn)
        assert kw["presentValue"] == 2
        assert kw["numberOfStates"] == 3
        assert kw["stateText"] == ["off", "on", "auto"]

    def test_no_default(self) -> None:
        defn = ObjectDefinition(object_type="AnalogValue", instance=1, name="x")
        kw = _extra_kwargs(defn)
        assert "presentValue" not in kw

    def test_analog_output_out_of_service(self) -> None:
        defn = ObjectDefinition(
            object_type="AnalogOutput", instance=1, name="ao", default=50.0, units="percent"
        )
        kw = _extra_kwargs(defn)
        assert kw["outOfService"] is False


class TestBuildBp3Object:
    def test_analog_input(self) -> None:
        defn = ObjectDefinition(
            object_type="AnalogInput", instance=5, name="sensor_005", units="noUnits", default=0
        )
        obj = _build_bp3_object(defn)
        assert isinstance(obj, AnalogInputObject)
        assert obj.objectName == "sensor_005"

    def test_analog_value(self) -> None:
        defn = ObjectDefinition(
            object_type="AnalogValue",
            instance=1,
            name="energy",
            units="kilowattHours",
            default=100.0,
        )
        obj = _build_bp3_object(defn)
        assert isinstance(obj, AnalogValueObject)

    def test_binary_value(self) -> None:
        defn = ObjectDefinition(
            object_type="BinaryValue", instance=1, name="lifebit", default=True
        )
        obj = _build_bp3_object(defn)
        assert isinstance(obj, BinaryValueObject)

    def test_multistate_value(self) -> None:
        defn = ObjectDefinition(
            object_type="MultiStateValue",
            instance=1,
            name="mode",
            default=1,
            states=("off", "heat"),
        )
        obj = _build_bp3_object(defn)
        assert isinstance(obj, MultiStateValueObject)

    def test_unknown_type_returns_none(self) -> None:
        defn = ObjectDefinition(object_type="TrendLog", instance=1, name="tl")
        assert _build_bp3_object(defn) is None


class TestMakeDeviceObject:
    def test_device_object_fields(self) -> None:
        profile = make_profile(
            model_name="TestDev",
            vendor="Generic",
            vendor_id=0,
            max_apdu=480,
            segmentation=SegmentationSupport.NO_SEGMENTATION,
        )
        dev_obj = _make_device_object(42, profile)
        assert dev_obj.objectName == "TestDev_42"
        assert dev_obj.maxApduLengthAccepted == 480
        assert str(dev_obj.segmentationSupported) == "no-segmentation"
        assert dev_obj.vendorIdentifier == 0
        assert dev_obj.protocolRevision == 22

    def test_segmented_both(self) -> None:
        profile = make_profile(segmentation=SegmentationSupport.SEGMENTED_BOTH)
        dev_obj = _make_device_object(1, profile)
        assert str(dev_obj.segmentationSupported) == "segmented-both"


class TestMakeAbortException:
    def test_buffer_overflow(self) -> None:
        exc_cls = _make_abort_exception(AbortReason.bufferOverflow)
        assert issubclass(exc_cls, AbortException)
        assert exc_cls.__name__ == "AbortbufferOverflow"
        assert exc_cls.abortReason == "bufferOverflow"

    def test_apdu_too_long(self) -> None:
        exc_cls = _make_abort_exception(11)
        assert issubclass(exc_cls, AbortException)
        assert exc_cls.abortReason == "apduTooLong"

    def test_unknown_code_falls_back_to_other(self) -> None:
        exc_cls = _make_abort_exception(255)
        assert exc_cls.abortReason == "other"

    def test_exception_is_raiseable(self) -> None:
        exc_cls = _make_abort_exception(AbortReason.bufferOverflow)
        with pytest.raises(AbortException):
            raise exc_cls()


class TestRealismForceAbortLogic:
    """Test the force_abort config field used by SlowApplication."""

    def test_default_no_force(self) -> None:
        r = RealismConfig(abort_reason=11)
        assert r.force_abort is False

    def test_explicit_force(self) -> None:
        r = RealismConfig(abort_reason=11, force_abort=True)
        assert r.force_abort is True

    def test_no_force_by_default(self) -> None:
        r = RealismConfig(abort_reason=0)
        assert r.force_abort is False
