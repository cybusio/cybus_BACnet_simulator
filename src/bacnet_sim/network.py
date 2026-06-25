"""BACnet/IP network layer using bacpypes3.

Creates one NormalApplication per virtual device, each bound to its own
UDP port (base_port + device_offset).  Every application hosts a real BACnet
device that responds to WhoIs, ReadProperty, WriteProperty, and
ReadPropertyMultiple on the wire.
"""

from __future__ import annotations

import asyncio
import logging
import random
import re
import weakref
from typing import TYPE_CHECKING
from typing import Any

from bacpypes3.apdu import AbortReason
from bacpypes3.apdu import ReadPropertyACK
from bacpypes3.appservice import ServerSSM
from bacpypes3.errors import AbortException
from bacpypes3.errors import ExecutionError
from bacpypes3.errors import PropertyError
from bacpypes3.ipv4.app import NormalApplication
from bacpypes3.object import AnalogInputObject
from bacpypes3.object import AnalogOutputObject
from bacpypes3.object import AnalogValueObject
from bacpypes3.object import BinaryInputObject
from bacpypes3.object import BinaryOutputObject
from bacpypes3.object import BinaryValueObject
from bacpypes3.object import DeviceObject
from bacpypes3.object import MultiStateInputObject
from bacpypes3.object import MultiStateOutputObject
from bacpypes3.object import MultiStateValueObject
from bacpypes3.object import NotificationClassObject
from bacpypes3.pdu import IPv4Address

if TYPE_CHECKING:
    from bacnet_sim.devices import DeviceManager
    from bacnet_sim.devices import VirtualDevice
    from bacnet_sim.types import DeviceProfile
    from bacnet_sim.types import ObjectDefinition
    from bacnet_sim.types import RealismConfig

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Object type mapping
# ---------------------------------------------------------------------------

_BP3_OBJECT_CLASS: dict[str, type] = {
    "AnalogInput": AnalogInputObject,
    "AnalogOutput": AnalogOutputObject,
    "AnalogValue": AnalogValueObject,
    "BinaryInput": BinaryInputObject,
    "BinaryOutput": BinaryOutputObject,
    "BinaryValue": BinaryValueObject,
    "MultiStateInput": MultiStateInputObject,
    "MultiStateOutput": MultiStateOutputObject,
    "MultiStateValue": MultiStateValueObject,
    "NotificationClass": NotificationClassObject,
}


def _type_id(name: str) -> str:
    """Derive a bacpypes3 object-type ID string from a CamelCase class name.

    Examples:
        "AnalogInput"      -> "analog-input"
        "BinaryValue"      -> "binary-value"
        "MultiStateInput"  -> "multi-state-input"
        "NotificationClass"-> "notification-class"
    """
    return re.sub(r"(?<=[a-z])([A-Z])", r"-\1", name).lower()


# ---------------------------------------------------------------------------
# Object builder
# ---------------------------------------------------------------------------


def _extra_kwargs(defn: ObjectDefinition) -> dict[str, Any]:
    """Return type-family-specific kwargs for a bacpypes3 object."""
    kw: dict[str, Any] = {}
    if defn.object_type.startswith("Analog"):
        if defn.default is not None:
            kw["presentValue"] = float(defn.default)
        if defn.units:
            kw["units"] = defn.units
    elif defn.object_type.startswith("Binary"):
        if defn.default is not None:
            kw["presentValue"] = "active" if defn.default else "inactive"
    elif defn.object_type.startswith("MultiState"):
        if defn.default is not None:
            kw["presentValue"] = int(defn.default)
        if defn.states:
            kw["numberOfStates"] = len(defn.states)
            kw["stateText"] = list(defn.states)
    if defn.object_type.endswith(("Input", "Output")):
        kw["outOfService"] = False
    return kw


def _build_bp3_object(defn: ObjectDefinition) -> Any:  # noqa: ANN401
    """Create a bacpypes3 object from our ObjectDefinition."""
    bp3_cls = _BP3_OBJECT_CLASS.get(defn.object_type)
    if bp3_cls is None:
        logger.warning(
            "Skipping unknown object type %r (instance %d)", defn.object_type, defn.instance
        )
        return None
    type_id = _type_id(defn.object_type)
    kwargs: dict[str, Any] = {
        "objectIdentifier": (type_id, defn.instance),
        "objectName": defn.name,
        **_extra_kwargs(defn),
    }
    return bp3_cls(**kwargs)


def _make_device_object(device_id: int, profile: DeviceProfile) -> DeviceObject:
    """Create a bacpypes3 DeviceObject from our profile."""
    seg_str = profile.network.segmentation.bp3_string
    return DeviceObject(
        objectIdentifier=("device", device_id),
        objectName=f"{profile.model_name}_{device_id}",
        maxApduLengthAccepted=profile.network.max_apdu,
        segmentationSupported=seg_str,
        vendorIdentifier=profile.vendor_id,
        vendorName=profile.vendor_name,
        modelName=profile.model_name,
        firmwareRevision=profile.firmware_revision,
        applicationSoftwareVersion=profile.application_software_version,
        protocolRevision=profile.protocol_revision,
        systemStatus="operational",
    )


# ---------------------------------------------------------------------------
# Abort reason patch: real devices send different abort codes instead of
# the ASHRAE-correct segmentationNotSupported (4).
#
# Per-instance: each application registers its abort reason keyed by its
# ASAP (ApplicationServiceAccessPoint) identity.  The SSM navigates
# self.ssmSAP to find the correct override for the device that owns it.
# ---------------------------------------------------------------------------

_original_ssm_abort = ServerSSM.abort
_abort_reasons: weakref.WeakKeyDictionary[Any, int] = weakref.WeakKeyDictionary()


def _patched_ssm_abort(self: ServerSSM, reason: int) -> Any:  # noqa: ANN401
    """Replace segmentationNotSupported with the per-device abort reason."""
    if reason == AbortReason.segmentationNotSupported:
        override = _abort_reasons.get(self.ssmSAP)
        if override is not None:
            reason = override
    return _original_ssm_abort(self, reason)


ServerSSM.abort = _patched_ssm_abort

# ---------------------------------------------------------------------------
# Abort reason helpers
# ---------------------------------------------------------------------------

_ABORT_REASON_NAMES: dict[int, str] = {
    v: k for k, v in AbortReason.__dict__.items() if isinstance(v, int)
}


def _make_abort_exception(abort_code: int) -> type[AbortException]:
    """Create an AbortException subclass for a given abort reason code.

    bacpypes3's Application.indication() catches AbortException and sends
    a proper AbortPDU through the SSM, producing exactly one abort packet
    with clean transaction cleanup.
    """
    reason_name = _ABORT_REASON_NAMES.get(abort_code, "other")
    return type(
        f"Abort{reason_name}",
        (AbortException,),
        {"abortReason": reason_name},
    )


# ---------------------------------------------------------------------------
# SlowApplication: realism layer (logging, delays, TSM, abort)
# ---------------------------------------------------------------------------


class SlowApplication(NormalApplication):  # type: ignore[misc]
    """NormalApplication with DEBUG logging and simulated hardware constraints.

    * DEBUG-level logging for all incoming requests
    * Response latency + jitter (slow embedded CPU)
    * TSM pool exhaustion (silently drop excess requests)
    * Force-abort: abort non-device reads with configured abort code

    With default RealismConfig (all zeros), behaves like a plain
    NormalApplication with logging. No separate class needed.
    """

    def __init__(
        self,
        device_object: Any,  # noqa: ANN401
        address: Any,  # noqa: ANN401
        realism: RealismConfig,
    ) -> None:
        super().__init__(device_object, address)
        self._realism = realism
        self._in_flight = 0
        self._tsm_limit = realism.tsm_pool_size
        # force_abort=true: abort ALL non-device reads immediately (skip processing)
        # force_abort=false: let natural segmentation handle it — small reads work,
        #   oversized responses abort via SSM with the configured abort_reason code
        self._force_abort = realism.force_abort
        self._abort_exc = _make_abort_exception(realism.abort_reason)

    async def do_ReadPropertyRequest(self, apdu: Any) -> None:  # noqa: ANN401, N802
        """Abort when force-abort is on, or when encoded response exceeds max_apdu.

        bacpypes3's SSM doesn't check response size for ReadPropertyACK
        (pduData is not populated before the segmentation check), so we
        replicate what real embedded firmware does: encode the response,
        measure it, and abort if it exceeds the device's max_apdu.
        """
        oid = apdu.objectIdentifier
        prop = apdu.propertyIdentifier
        src = apdu.pduSource
        if self._force_abort and str(oid[0]) != "device":
            reason = self._realism.abort_reason
            logger.debug("RP %s/%s from %s -> abort(%d)", oid, prop, src, reason)
            raise self._abort_exc()
        # Natural APDU size check — only when abort_reason is configured
        if self._realism.abort_reason != 0:
            await self._read_property_with_size_check(apdu)
        else:
            logger.debug("RP %s/%s from %s -> ok", oid, prop, src)
            await super().do_ReadPropertyRequest(apdu)

    async def _read_property_with_size_check(self, apdu: Any) -> None:  # noqa: ANN401
        """Read property with APDU response size enforcement.

        Builds the ReadPropertyACK, encodes it, and aborts if the encoded
        size exceeds maxApduLengthAccepted — matching real device behavior.
        """
        obj = self.get_object_id(apdu.objectIdentifier)
        if not obj:
            raise ExecutionError(errorClass="object", errorCode="unknownObject")
        value = await obj.read_property(
            apdu.propertyIdentifier,
            apdu.propertyArrayIndex,
        )
        if value is None:
            raise PropertyError(errorCode="unknownProperty")
        resp = ReadPropertyACK(
            objectIdentifier=apdu.objectIdentifier,
            propertyIdentifier=apdu.propertyIdentifier,
            propertyArrayIndex=apdu.propertyArrayIndex,
            propertyValue=value,
            context=apdu,
        )
        encoded = resp.encode()
        apdu_size = len(encoded.pduData) if encoded.pduData else 0
        max_apdu = self.device_object.maxApduLengthAccepted
        if apdu_size > max_apdu:
            logger.debug(
                "RP %s/%s from %s -> abort(%d), %dB > max_apdu %d",
                apdu.objectIdentifier,
                apdu.propertyIdentifier,
                apdu.pduSource,
                self._realism.abort_reason,
                apdu_size,
                max_apdu,
            )
            raise self._abort_exc()
        logger.debug(
            "RP %s/%s from %s -> ok, %dB",
            apdu.objectIdentifier,
            apdu.propertyIdentifier,
            apdu.pduSource,
            apdu_size,
        )
        await self.response(resp)

    async def do_ReadPropertyMultipleRequest(self, apdu: Any) -> None:  # noqa: ANN401, N802
        """Always abort RPM when force-abort is on."""
        src = apdu.pduSource
        if self._force_abort:
            logger.debug("RPM from %s -> abort(%d)", src, self._realism.abort_reason)
            raise self._abort_exc()
        logger.debug("RPM from %s -> ok", src)
        await super().do_ReadPropertyMultipleRequest(apdu)

    async def do_WritePropertyRequest(self, apdu: Any) -> None:  # noqa: ANN401, N802
        """Log and forward WriteProperty."""
        logger.debug(
            "WP %s/%s from %s -> ok",
            apdu.objectIdentifier,
            apdu.propertyIdentifier,
            apdu.pduSource,
        )
        await super().do_WritePropertyRequest(apdu)

    async def indication(self, apdu: Any) -> None:  # noqa: ANN401
        """Process incoming APDU with simulated hardware constraints."""
        # Force-abort bypasses delay — real devices abort immediately
        if self._force_abort:
            await super().indication(apdu)
            return

        # TSM pool exhaustion — silently drop
        if self._tsm_limit > 0 and self._in_flight >= self._tsm_limit:
            logger.debug("TSM pool full (%d/%d), dropping", self._in_flight, self._tsm_limit)
            return

        self._in_flight += 1
        try:
            delay_s = self._realism.response_delay_ms / 1000.0
            if self._realism.response_jitter_ms > 0:
                delay_s += random.uniform(0, self._realism.response_jitter_ms / 1000.0)  # noqa: S311
            if delay_s > 0:
                await asyncio.sleep(delay_s)
            await super().indication(apdu)
        finally:
            self._in_flight -= 1


# ---------------------------------------------------------------------------
# DeviceApp + BACnetNetwork
# ---------------------------------------------------------------------------


class DeviceApp:
    """Wraps a bacpypes3 NormalApplication for one virtual device."""

    __slots__ = ("_drift_task", "app", "device_id", "port")

    def __init__(
        self,
        device: VirtualDevice,
        port: int,
        bind_address: str = "0.0.0.0",  # noqa: S104
    ) -> None:
        dev_obj = _make_device_object(device.device_id, device.profile)
        addr = IPv4Address(f"{bind_address}:{port}")
        realism = device.profile.realism
        self.app = SlowApplication(dev_obj, addr, realism)
        # Register per-instance SSM abort reason override
        if realism.abort_reason != 0:
            _abort_reasons[self.app.asap] = realism.abort_reason
        self.device_id = device.device_id
        self.port = port

        for obj_def in device.profile.objects:
            bp3_obj = _build_bp3_object(obj_def)
            if bp3_obj is not None:
                self.app.add_object(bp3_obj)

        obj_list = [obj.objectIdentifier for obj in self.app.iter_objects()]
        dev_obj.objectList = obj_list
        self._drift_task: asyncio.Task[None] | None = None

        logger.info(
            "Device %d (%s) on UDP %s:%d with %d objects",
            device.device_id,
            device.profile.model_name,
            bind_address,
            port,
            len(obj_list) - 1,
        )

    def start_drift(self) -> None:
        """Start ±2% value drift on AnalogInput objects every 5s."""
        targets: list[tuple[Any, float]] = []
        for obj in self.app.iter_objects():
            oid = obj.objectIdentifier
            if str(oid[0]) == "analog-input" and hasattr(obj, "presentValue"):
                try:
                    val = float(obj.presentValue)
                except (TypeError, ValueError):
                    continue
                if val != 0:
                    targets.append((obj, val))
        if targets:
            self._drift_task = asyncio.create_task(self._drift_loop(targets))

    async def _drift_loop(self, targets: list[tuple[Any, float]]) -> None:
        """Background loop: nudge analog inputs around their baseline."""
        while True:
            await asyncio.sleep(5)
            for obj, base in targets:
                obj.presentValue = round(base * (1 + random.uniform(-0.02, 0.02)), 2)  # noqa: S311

    def close(self) -> None:
        """Shut down the bacpypes3 application."""
        if self._drift_task:
            self._drift_task.cancel()
        _abort_reasons.pop(self.app.asap, None)
        self.app.close()


class BACnetNetwork:
    """Manages bacpypes3 applications for all virtual devices."""

    def __init__(self, manager: DeviceManager) -> None:
        self._manager = manager
        self._apps: list[DeviceApp] = []

    async def start(
        self,
        base_port: int = 47808,
        bind_address: str = "0.0.0.0",  # noqa: S104
    ) -> None:
        """Start device applications. Uses simulator.port from profile if set."""
        for offset, device in enumerate(self._manager.broadcast()):
            port = device.profile.simulator_port or (base_port + offset)
            try:
                app = DeviceApp(device, port, bind_address)
                app.start_drift()
                self._apps.append(app)
            except Exception:
                logger.exception("Failed to start device %d", device.device_id)
        await asyncio.sleep(0.1)
        if self._apps:
            logger.info(
                "BACnet network started: %d devices on ports %d-%d",
                len(self._apps),
                base_port,
                base_port + len(self._apps) - 1,
            )
        else:
            msg = "No devices started"
            logger.warning(msg)
            raise RuntimeError(msg)

    async def stop(self) -> None:
        """Stop all device applications."""
        for app in self._apps:
            try:
                app.close()
            except Exception:
                logger.exception("Error closing device %d", app.device_id)
        self._apps.clear()
        logger.info("BACnet network stopped")

    def port_map(self) -> dict[int, int]:
        """Return device_id -> UDP port mapping."""
        return {app.device_id: app.port for app in self._apps}
