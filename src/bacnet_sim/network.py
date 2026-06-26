"""BACnet/IP network layer using bacpypes3.

Creates one NormalApplication per virtual device, each bound to its own
UDP port (base_port + device_offset).  Every application hosts a real BACnet
device that responds to WhoIs, ReadProperty, WriteProperty, and
ReadPropertyMultiple on the wire.
"""

from __future__ import annotations

import asyncio
import logging
import os
import random
import re
import weakref
from typing import TYPE_CHECKING
from typing import Any

from bacpypes3.apdu import AbortReason
from bacpypes3.apdu import APCISequence
from bacpypes3.apdu import ComplexAckPDU
from bacpypes3.apdu import ReadPropertyACK
from bacpypes3.apdu import ReadRangeACK
from bacpypes3.appservice import ServerSSM
from bacpypes3.basetypes import EventTransitionBits
from bacpypes3.basetypes import ResultFlags
from bacpypes3.errors import AbortException
from bacpypes3.errors import ExecutionError
from bacpypes3.errors import PropertyError
from bacpypes3.errors import UnrecognizedService
from bacpypes3.ipv4.app import NormalApplication
from bacpypes3.local.analog import AnalogInputObject as LocalAnalogInputObject
from bacpypes3.local.analog import AnalogOutputObject as LocalAnalogOutputObject
from bacpypes3.local.analog import AnalogValueObject as LocalAnalogValueObject
from bacpypes3.local.binary import BinaryInputObject as LocalBinaryInputObject
from bacpypes3.local.binary import BinaryOutputObject as LocalBinaryOutputObject
from bacpypes3.local.binary import BinaryValueObject as LocalBinaryValueObject
from bacpypes3.local.device import DeviceObject
from bacpypes3.local.multistate import MultiStateInputObject as LocalMultiStateInputObject
from bacpypes3.local.multistate import MultiStateOutputObject as LocalMultiStateOutputObject
from bacpypes3.local.multistate import MultiStateValueObject as LocalMultiStateValueObject
from bacpypes3.object import AnalogInputObject
from bacpypes3.object import AnalogOutputObject
from bacpypes3.object import AnalogValueObject
from bacpypes3.object import BinaryInputObject
from bacpypes3.object import BinaryOutputObject
from bacpypes3.object import BinaryValueObject
from bacpypes3.object import MultiStateInputObject
from bacpypes3.object import MultiStateOutputObject
from bacpypes3.object import MultiStateValueObject
from bacpypes3.object import NotificationClassObject
from bacpypes3.pdu import IPv4Address

from bacnet_sim.cov import DriverRegistry

if TYPE_CHECKING:
    from bacnet_sim.devices import DeviceManager
    from bacnet_sim.devices import VirtualDevice
    from bacnet_sim.types import DeviceProfile
    from bacnet_sim.types import ObjectDefinition
    from bacnet_sim.types import RealismConfig

logger = logging.getLogger(__name__)

# Test-only network-loss hook. Default 0.0 (disabled). Set BACNET_PACKET_DROP_PROB
# to a float in (0, 1] to drop that fraction of incoming APDUs before any device
# processing. Used by Phase 6 soak tests; must be 0.0 for all normal runs.
_PACKET_DROP_PROB = max(
    0.0, min(1.0, float(os.environ.get("BACNET_PACKET_DROP_PROB", "0") or "0"))
)
if _PACKET_DROP_PROB > 0:
    logger.warning("BACNET_PACKET_DROP_PROB=%.2f — dropping incoming APDUs", _PACKET_DROP_PROB)

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

# COV-capable variants from bacpypes3.local.*. Used only when a profile opts in
# (cov_increment or drive set) to avoid disrupting existing profiles that rely
# on the simpler bacpypes3.object.* classes.
_BP3_LOCAL_OBJECT_CLASS: dict[str, type] = {
    "AnalogInput": LocalAnalogInputObject,
    "AnalogOutput": LocalAnalogOutputObject,
    "AnalogValue": LocalAnalogValueObject,
    "BinaryInput": LocalBinaryInputObject,
    "BinaryOutput": LocalBinaryOutputObject,
    "BinaryValue": LocalBinaryValueObject,
    "MultiStateInput": LocalMultiStateInputObject,
    "MultiStateOutput": LocalMultiStateOutputObject,
    "MultiStateValue": LocalMultiStateValueObject,
}


def _object_uses_cov(defn: ObjectDefinition) -> bool:
    """A definition opts into COV when cov_increment or drive is configured."""
    return defn.cov_increment is not None or defn.drive is not None


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


def _analog_kwargs(defn: ObjectDefinition) -> dict[str, Any]:
    kw: dict[str, Any] = {}
    if defn.default is not None:
        kw["presentValue"] = float(defn.default)
    if defn.units:
        kw["units"] = defn.units
    if defn.cov_increment is not None:
        kw["covIncrement"] = float(defn.cov_increment)
    return kw


def _binary_kwargs(defn: ObjectDefinition) -> dict[str, Any]:
    kw: dict[str, Any] = {}
    if defn.default is not None:
        kw["presentValue"] = "active" if defn.default else "inactive"
    return kw


def _multistate_kwargs(defn: ObjectDefinition) -> dict[str, Any]:
    kw: dict[str, Any] = {}
    if defn.default is not None:
        kw["presentValue"] = int(defn.default)
    if defn.states:
        kw["numberOfStates"] = len(defn.states)
        kw["stateText"] = list(defn.states)
    return kw


def _extra_kwargs(defn: ObjectDefinition) -> dict[str, Any]:
    """Return type-family-specific kwargs for a bacpypes3 object."""
    kw: dict[str, Any]
    if defn.object_type.startswith("Analog"):
        kw = _analog_kwargs(defn)
    elif defn.object_type.startswith("Binary"):
        kw = _binary_kwargs(defn)
    elif defn.object_type.startswith("MultiState"):
        kw = _multistate_kwargs(defn)
    else:
        kw = {}
    if defn.object_type.endswith(("Input", "Output")):
        kw["outOfService"] = False
    return kw


def _build_bp3_object(defn: ObjectDefinition) -> Any:  # noqa: ANN401
    """Create a bacpypes3 object from our ObjectDefinition.

    Switches to bacpypes3.local.* variants when the object opts into COV
    (cov_increment or drive set). Local classes register a `_cov_criteria`
    detection algorithm that fires notifications via the parent app's
    ChangeOfValueServices mixin.
    """
    if _object_uses_cov(defn) and defn.object_type in _BP3_LOCAL_OBJECT_CLASS:
        bp3_cls: type | None = _BP3_LOCAL_OBJECT_CLASS[defn.object_type]
    else:
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
    # NC required properties — bacpypes3 leaves them None otherwise
    if defn.object_type == "NotificationClass":
        kwargs["notificationClass"] = defn.instance
        kwargs["priority"] = [64, 64, 64]
        kwargs["ackRequired"] = EventTransitionBits([1, 1, 1])
        kwargs["recipientList"] = []
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
        self._disable_rpm = realism.disable_rpm
        self._overload_abort = realism.overload_abort
        self._overload_drop_prob = realism.overload_drop_prob
        self._cov_limit = realism.cov_subscription_limit
        self._cov_active = 0

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
        # Overload abort: when saturated, the station's transaction buffer
        # overflows and it ABORTs the excess read (CC-3851). Device reads (the
        # liveness probe) are spared so the connection stays "connected" and
        # keeps polling — which is what drives the client's invoke-id pressure.
        if (
            self._overload_abort
            and self._tsm_limit > 0
            and self._in_flight > self._tsm_limit
            and str(oid[0]) != "device"
        ):
            logger.debug(
                "RP %s/%s from %s -> overload abort(%d)",
                oid,
                prop,
                src,
                self._realism.abort_reason,
            )
            raise self._abort_exc()
        # force_abort aborts non-device reads; abort_device_reads extends it to
        # the device object too (e.g. object-name liveness probe) so the client's
        # probe error-classification can be exercised.
        abort_this = self._force_abort and (
            self._realism.abort_device_reads or str(oid[0]) != "device"
        )
        if abort_this:
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

    async def do_ReadRangeRequest(self, apdu: Any) -> None:  # noqa: ANN401, N802
        """ReadRange By Position over a list/array property (bacpypes3 stubs this).

        Returns a window of the property capped to the device APDU, with
        firstItem/lastItem/moreItems flags so the client reads the rest in chunks.
        """
        obj = self.get_object_id(apdu.objectIdentifier)
        if not obj:
            raise ExecutionError(errorClass="object", errorCode="unknownObject")
        value = await obj.read_property(apdu.propertyIdentifier, None)
        if value is None:
            raise PropertyError(errorCode="unknownProperty")
        try:
            elements = list(value)
        except TypeError as exc:
            raise ExecutionError(errorClass="property", errorCode="datatypeNotSupported") from exc
        total = len(elements)
        ref_index, count = 1, total
        rng = apdu.range
        by_pos = getattr(rng, "byPosition", None) if rng is not None else None
        if by_pos is not None:
            ref_index = int(by_pos.referenceIndex)
            count = int(by_pos.count)
        start = max(ref_index - 1, 0)
        avail = max(total - start, 0)
        cap = max(1, self.device_object.maxApduLengthAccepted // 8)
        take = min(count if count > 0 else avail, avail, cap)
        sliced = elements[start : start + take]
        last_item = (start + take) >= total
        resp = ReadRangeACK(
            objectIdentifier=apdu.objectIdentifier,
            propertyIdentifier=apdu.propertyIdentifier,
            resultFlags=ResultFlags(
                [1 if start == 0 else 0, 1 if last_item else 0, 0 if last_item else 1]
            ),
            itemCount=len(sliced),
            itemData=type(value)(sliced),
            context=apdu,
        )
        logger.debug(
            "RR %s/%s from %s -> %d items (start=%d more=%s)",
            apdu.objectIdentifier,
            apdu.propertyIdentifier,
            apdu.pduSource,
            len(sliced),
            start,
            not last_item,
        )
        await self.response(resp)

    async def do_ReadPropertyMultipleRequest(self, apdu: Any) -> None:  # noqa: ANN401, N802
        """Reject RPM when disabled; abort when force-abort is on."""
        src = apdu.pduSource
        if self._disable_rpm:
            logger.debug("RPM from %s -> reject(unrecognizedService)", src)
            raise UnrecognizedService
        if self._force_abort:
            logger.debug("RPM from %s -> abort(%d)", src, self._realism.abort_reason)
            raise self._abort_exc()
        logger.debug("RPM from %s -> ok", src)
        await super().do_ReadPropertyMultipleRequest(apdu)

    async def do_SubscribeCOVRequest(self, apdu: Any) -> None:  # noqa: ANN401, N802
        """Finite COV subscription table (models a real B-BC like the PXC).

        Beyond cov_subscription_limit, reject so the client must fall back to
        polling for the excess points -- the realistic at-scale behaviour.
        """
        is_cancel = getattr(apdu, "lifetime", None) in (None, 0)
        if not is_cancel and self._cov_limit and self._cov_active >= self._cov_limit:
            logger.debug(
                "SubscribeCOV from %s -> COV table full (%d)", apdu.pduSource, self._cov_limit
            )
            raise ExecutionError(errorClass="services", errorCode="cov-subscription-failed")
        await super().do_SubscribeCOVRequest(apdu)
        self._cov_active = max(0, self._cov_active - 1) if is_cancel else self._cov_active + 1

    async def response(self, apdu: Any) -> None:  # noqa: ANN401
        """Abort ComplexAck responses that exceed the device's max APDU.

        Catches all outgoing ComplexAck PDUs (RPM, RP, ReadRange, etc.) and
        aborts if the encoded size would exceed maxApduLengthAccepted. This
        matches real embedded device behavior where the firmware checks response
        size before transmitting.
        """
        if (
            self._realism.abort_reason != 0
            and isinstance(apdu, APCISequence)
            and isinstance(apdu, ComplexAckPDU)
        ):
            encoded = apdu.encode()
            apdu_size = len(encoded.pduData) if encoded.pduData else 0
            max_apdu = self.device_object.maxApduLengthAccepted
            if apdu_size > max_apdu:
                logger.debug(
                    "Response %s -> abort(%d), %dB > max_apdu %d",
                    type(apdu).__name__,
                    self._realism.abort_reason,
                    apdu_size,
                    max_apdu,
                )
                raise self._abort_exc()
        await super().response(apdu)

    async def do_WritePropertyRequest(self, apdu: Any) -> None:  # noqa: ANN401, N802
        """Abort writes under force_abort; otherwise log and forward.

        Mirrors the pcap's write ABORTs.
        """
        if self._force_abort:
            reason = self._realism.abort_reason
            logger.debug(
                "WP %s/%s from %s -> abort(%d)",
                apdu.objectIdentifier,
                apdu.propertyIdentifier,
                apdu.pduSource,
                reason,
            )
            raise self._abort_exc()
        logger.debug(
            "WP %s/%s from %s -> ok",
            apdu.objectIdentifier,
            apdu.propertyIdentifier,
            apdu.pduSource,
        )
        await super().do_WritePropertyRequest(apdu)

    async def indication(self, apdu: Any) -> None:  # noqa: ANN401
        """Process incoming APDU with simulated hardware constraints."""
        # Simulated link-layer loss — drop before any device processing
        if _PACKET_DROP_PROB > 0 and random.random() < _PACKET_DROP_PROB:  # noqa: S311
            logger.debug("Lossy net: dropping incoming APDU from %s", apdu.pduSource)
            return

        # Force-abort bypasses delay — real devices abort immediately
        if self._force_abort:
            await super().indication(apdu)
            return

        # TSM pool exhaustion. Without overload_abort: silently drop (timeout).
        # With overload_abort: emit a bufferOverflow ABORT for the excess read —
        # counted in-flight so the handler sees saturation (in_flight > limit),
        # but no delay and it never occupies a serving slot, so the pool still
        # serves its quota of real reads.
        if self._tsm_limit > 0 and self._in_flight >= self._tsm_limit:
            if not self._overload_abort:
                logger.debug("TSM pool full (%d/%d), dropping", self._in_flight, self._tsm_limit)
                return
            # Real station under overload does both: drop a fraction (-> client
            # timeout), abort the rest with bufferOverflow.
            if self._overload_drop_prob > 0 and random.random() < self._overload_drop_prob:  # noqa: S311
                logger.debug(
                    "TSM pool full (%d/%d), overload drop", self._in_flight, self._tsm_limit
                )
                return
            self._in_flight += 1
            try:
                await super().indication(apdu)
            finally:
                self._in_flight -= 1
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

    __slots__ = ("_drift_pct", "_drift_task", "_driver_registry", "app", "device_id", "port")

    def __init__(
        self,
        device: VirtualDevice,
        port: int,
        bind_address: str = "0.0.0.0",  # noqa: S104
    ) -> None:
        dev_obj = _make_device_object(device.device_id, device.profile)
        addr = IPv4Address(f"{bind_address}/32:{port}")
        realism = device.profile.realism
        self.app = SlowApplication(dev_obj, addr, realism)
        # Register per-instance SSM abort reason override
        if realism.abort_reason != 0:
            _abort_reasons[self.app.asap] = realism.abort_reason
        self.device_id = device.device_id
        self.port = port
        self._drift_pct = realism.drift_pct

        self._driver_registry = DriverRegistry()
        for obj_def in device.profile.objects:
            bp3_obj = _build_bp3_object(obj_def)
            if bp3_obj is None:
                continue
            self.app.add_object(bp3_obj)
            if obj_def.drive is not None:
                self._driver_registry.add(bp3_obj, obj_def.drive)

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
        """Start value drift on AnalogInput objects every 5s.

        realism.drift_pct default ±2%; 0 = static values (e.g. for data-integrity
        verification). Also starts any profile-configured COV value drivers via
        DriverRegistry.
        """
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
        if targets and self._drift_pct > 0:
            self._drift_task = asyncio.create_task(self._drift_loop(targets))
        self._driver_registry.start()

    async def _drift_loop(self, targets: list[tuple[Any, float]]) -> None:
        """Background loop: nudge analog inputs around their baseline."""
        while True:
            await asyncio.sleep(5)
            for obj, base in targets:
                # jitter is cosmetic telemetry noise, not a security primitive
                jitter = random.uniform(-self._drift_pct, self._drift_pct)  # noqa: S311
                obj.presentValue = round(base * (1 + jitter), 2)

    def close(self) -> None:
        """Shut down the bacpypes3 application."""
        if self._drift_task:
            self._drift_task.cancel()
        self._driver_registry.stop()
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
