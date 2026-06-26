"""Tests for the COV-emitter profile (Subscribe-COV server-side).

Spins up a real SlowApplication on loopback with COV-capable objects and
drives it with a second bacpypes3 client app on a different UDP port.
The two apps exchange real BACnet/IP APDUs through the kernel UDP stack.

Each test owns its own client/emitter pair so failures don't cascade.
"""

from __future__ import annotations

import asyncio
import contextlib
import dataclasses
import shutil
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
from bacpypes3.apdu import ConfirmedCOVNotificationRequest
from bacpypes3.apdu import SimpleAckPDU
from bacpypes3.apdu import SubscribeCOVRequest
from bacpypes3.apdu import UnconfirmedCOVNotificationRequest
from bacpypes3.ipv4.app import NormalApplication
from bacpypes3.local.device import DeviceObject
from bacpypes3.pdu import Address
from bacpypes3.pdu import IPv4Address
from bacpypes3.primitivedata import ObjectIdentifier

from bacnet_sim.devices import DeviceManager
from bacnet_sim.devices import VirtualDevice
from bacnet_sim.network import BACnetNetwork
from bacnet_sim.profiles import ProfileLoader

# Loopback ports for emitter and client. Each test increments to avoid collisions
# if a previous run leaked a socket.
_EMITTER_PORT_BASE = 57820
_CLIENT_PORT_BASE = 57850
_BIND = "127.0.0.1"

REPO_ROOT = Path(__file__).parent.parent
PROFILE_PATH = REPO_ROOT / "profiles-cybus" / "cov_emitter.yaml"
BASE_PATH = REPO_ROOT / "profiles" / "_base.yaml"
VENDORS_PATH = REPO_ROOT / "profiles" / "vendors.yaml"


# -- Fixtures -----------------------------------------------------------------


@dataclass
class CovRig:
    """Holds a running emitter network and a paired test-client app."""

    network: BACnetNetwork
    client: NormalApplication
    emitter_address: Address
    emitter_device_id: int
    client_proc_id: int


def _alloc_ports(idx: int) -> tuple[int, int]:
    return _EMITTER_PORT_BASE + idx, _CLIENT_PORT_BASE + idx


def _profile_dir(tmp: Path) -> Path:
    """Lay out a minimal profiles dir with only cov_emitter + _base/vendors."""
    if not PROFILE_PATH.exists():
        msg = f"cov_emitter profile missing: {PROFILE_PATH}"
        raise FileNotFoundError(msg)
    pdir = tmp / "profiles"
    pdir.mkdir(parents=True, exist_ok=True)
    shutil.copy(BASE_PATH, pdir / "_base.yaml")
    shutil.copy(VENDORS_PATH, pdir / "vendors.yaml")
    shutil.copy(PROFILE_PATH, pdir / "cov_emitter.yaml")
    return pdir


async def _make_emitter(port: int, tmp: Path) -> BACnetNetwork:
    """Spin up a one-device emitter network bound to loopback `port`."""
    loader = ProfileLoader(_profile_dir(tmp))
    profiles = [p for p in loader.load_all() if "cov" in p.model_name.lower()]
    assert profiles, "cov_emitter profile not loaded"
    profile = profiles[0]
    patched = dataclasses.replace(profile, simulator_port=port)
    mgr = DeviceManager()
    mgr._devices.append(
        VirtualDevice(device_id=patched.simulator_device_id or 900_001, profile=patched),
    )
    net = BACnetNetwork(mgr)
    await net.start(base_port=port, bind_address=_BIND)
    return net


async def _make_client(port: int) -> NormalApplication:
    dev = DeviceObject(
        objectIdentifier=("device", 999_001),
        objectName="cov-test-client",
        maxApduLengthAccepted=1476,
        segmentationSupported="segmentedBoth",
        vendorIdentifier=0,
    )
    return NormalApplication(dev, IPv4Address(f"{_BIND}/32:{port}"))


@pytest.fixture
async def rig(request: pytest.FixtureRequest, tmp_path: Path) -> Any:
    idx = getattr(request, "param", 0)
    e_port, c_port = _alloc_ports(idx)
    network = await _make_emitter(e_port, tmp_path)
    client = await _make_client(c_port)
    emitter_addr = Address(f"{_BIND}:{e_port}")
    # Pick the emitter device id off the started network
    emitter_id = next(iter(network.port_map().keys()))
    rig_ = CovRig(
        network=network,
        client=client,
        emitter_address=emitter_addr,
        emitter_device_id=emitter_id,
        client_proc_id=1,
    )
    try:
        yield rig_
    finally:
        client.close()
        await network.stop()
        await asyncio.sleep(0.05)


# -- Helpers ------------------------------------------------------------------


def _capture_notifications(app: NormalApplication) -> asyncio.Queue[Any]:
    """Monkey-patch the client's notification handlers to push into a queue."""
    q: asyncio.Queue[Any] = asyncio.Queue()
    orig_unconf = app.do_UnconfirmedCOVNotificationRequest
    orig_conf = app.do_ConfirmedCOVNotificationRequest

    async def cap_unconf(apdu: UnconfirmedCOVNotificationRequest) -> None:
        await q.put(("unconfirmed", apdu))
        await orig_unconf(apdu)

    async def cap_conf(apdu: ConfirmedCOVNotificationRequest) -> None:
        await q.put(("confirmed", apdu))
        await orig_conf(apdu)

    app.do_UnconfirmedCOVNotificationRequest = cap_unconf  # type: ignore[method-assign]
    app.do_ConfirmedCOVNotificationRequest = cap_conf  # type: ignore[method-assign]
    return q


# -- Tests --------------------------------------------------------------------


@pytest.mark.parametrize("rig", [0], indirect=True)
async def test_cov_subscribe_simple_ack(rig: CovRig) -> None:
    """Subscribe-COV on analog-value:1 returns SimpleACK within 200ms."""
    req = SubscribeCOVRequest(
        subscriberProcessIdentifier=rig.client_proc_id,
        monitoredObjectIdentifier=ObjectIdentifier(("analog-value", 1)),
        issueConfirmedNotifications=False,
        lifetime=60,
        destination=rig.emitter_address,
    )
    resp = await asyncio.wait_for(rig.client.request(req), timeout=0.2)
    msg = f"expected SimpleAck, got {type(resp).__name__}: {resp!r}"
    assert isinstance(resp, SimpleAckPDU), msg


@pytest.mark.parametrize("rig", [1], indirect=True)
async def test_cov_unconfirmed_notification_emitted(rig: CovRig) -> None:
    """Subscribe-COV unconfirmed yields a notification within 500ms."""
    q = _capture_notifications(rig.client)
    req = SubscribeCOVRequest(
        subscriberProcessIdentifier=rig.client_proc_id,
        monitoredObjectIdentifier=ObjectIdentifier(("analog-value", 1)),
        issueConfirmedNotifications=False,
        lifetime=60,
        destination=rig.emitter_address,
    )
    await rig.client.request(req)

    kind, apdu = await asyncio.wait_for(q.get(), timeout=0.5)
    assert kind == "unconfirmed"
    assert apdu.monitoredObjectIdentifier == ObjectIdentifier(("analog-value", 1))
    assert apdu.subscriberProcessIdentifier == rig.client_proc_id


@pytest.mark.parametrize("rig", [2], indirect=True)
async def test_cov_confirmed_notification_with_ack(rig: CovRig) -> None:
    """Subscribe-COV confirmed yields ConfirmedCOVNotification + SimpleAck."""
    q = _capture_notifications(rig.client)
    req = SubscribeCOVRequest(
        subscriberProcessIdentifier=rig.client_proc_id,
        monitoredObjectIdentifier=ObjectIdentifier(("analog-value", 1)),
        issueConfirmedNotifications=True,
        lifetime=60,
        destination=rig.emitter_address,
    )
    await rig.client.request(req)

    kind, apdu = await asyncio.wait_for(q.get(), timeout=2.0)
    assert kind == "confirmed"
    assert apdu.monitoredObjectIdentifier == ObjectIdentifier(("analog-value", 1))


@pytest.mark.parametrize("rig", [3], indirect=True)
async def test_cov_unsubscribe(rig: CovRig) -> None:
    """Cancel via Subscribe-COV w/o confirmed/lifetime stops notifications."""
    q = _capture_notifications(rig.client)
    # Subscribe
    sub = SubscribeCOVRequest(
        subscriberProcessIdentifier=rig.client_proc_id,
        monitoredObjectIdentifier=ObjectIdentifier(("analog-value", 1)),
        issueConfirmedNotifications=False,
        lifetime=60,
        destination=rig.emitter_address,
    )
    await rig.client.request(sub)
    # Drain the initial notification
    with contextlib.suppress(asyncio.TimeoutError):
        await asyncio.wait_for(q.get(), timeout=1.0)

    # Cancel
    cancel = SubscribeCOVRequest(
        subscriberProcessIdentifier=rig.client_proc_id,
        monitoredObjectIdentifier=ObjectIdentifier(("analog-value", 1)),
        destination=rig.emitter_address,
    )
    resp = await rig.client.request(cancel)
    assert isinstance(resp, SimpleAckPDU)

    # Wait past two driver cycles — must see no further notifications.
    # Drain the queue first to ignore residual notifications already in flight.
    while not q.empty():
        q.get_nowait()
    await asyncio.sleep(1.5)
    assert q.empty(), f"unexpected notification after cancel: {list(q._queue)!r}"


@pytest.mark.parametrize("rig", [4], indirect=True)
async def test_cov_lifetime_expiry(rig: CovRig) -> None:
    """Subscription with lifetime=2 stops emitting after expiry."""
    q = _capture_notifications(rig.client)
    req = SubscribeCOVRequest(
        subscriberProcessIdentifier=rig.client_proc_id,
        monitoredObjectIdentifier=ObjectIdentifier(("analog-value", 1)),
        issueConfirmedNotifications=False,
        lifetime=2,
        destination=rig.emitter_address,
    )
    await rig.client.request(req)
    # Drain anything in the first 2s window
    deadline = asyncio.get_event_loop().time() + 2.2
    while asyncio.get_event_loop().time() < deadline:
        with contextlib.suppress(asyncio.TimeoutError):
            await asyncio.wait_for(q.get(), timeout=0.2)
    # Drain any residual notifications already in flight at expiry boundary
    while not q.empty():
        q.get_nowait()

    # 1.5s past expiry, queue must stay empty.
    await asyncio.sleep(1.5)
    assert q.empty(), f"notification after lifetime expiry: {list(q._queue)!r}"
