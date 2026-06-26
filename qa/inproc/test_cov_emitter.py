"""End-to-end smoke test for the bacnet-cov-emitter service.

Pre-conditions:
    The bacnet-cov-emitter container must be running and listening on
    UDP 47820 (the profile-configured port). Bring it up with:

        docker compose up bacnet-cov-emitter

    or start the whole stack:

        docker compose up

Runs a bacpypes3 client on loopback, subscribes COV, waits for at least
one notification, cancels, and asserts no further notifications.

Skipped automatically when the emitter port is not reachable.
"""

from __future__ import annotations

import asyncio
import contextlib
from typing import Any

import pytest
from bacpypes3.apdu import SimpleAckPDU
from bacpypes3.apdu import SubscribeCOVRequest
from bacpypes3.apdu import UnconfirmedCOVNotificationRequest
from bacpypes3.ipv4.app import NormalApplication
from bacpypes3.local.device import DeviceObject
from bacpypes3.pdu import Address
from bacpypes3.pdu import IPv4Address
from bacpypes3.primitivedata import ObjectIdentifier

EMITTER_HOST = "127.0.0.1"
EMITTER_PORT = 47820
CLIENT_PORT = 47900
PROBE_PORT = 47902


async def _emitter_responds(host: str, port: int, timeout: float = 1.5) -> bool:
    """Send a WhoIs to the emitter and wait briefly for an I-Am."""
    dev = DeviceObject(
        objectIdentifier=("device", 999_998),
        objectName="cov-emitter-probe",
        maxApduLengthAccepted=1476,
        segmentationSupported="segmentedBoth",
        vendorIdentifier=0,
    )
    probe = NormalApplication(dev, IPv4Address(f"0.0.0.0/32:{PROBE_PORT}"))
    try:
        iams = await probe.who_is(address=Address(f"{host}:{port}"), timeout=timeout)
        return bool(iams)
    except Exception:
        return False
    finally:
        probe.close()
        await asyncio.sleep(0.05)


@pytest.fixture(scope="module")
async def emitter_address() -> Address:
    if not await _emitter_responds(EMITTER_HOST, EMITTER_PORT):
        pytest.skip(
            f"bacnet-cov-emitter not reachable on {EMITTER_HOST}:{EMITTER_PORT} "
            "(run: docker compose up bacnet-cov-emitter)",
        )
    return Address(f"{EMITTER_HOST}:{EMITTER_PORT}")


@pytest.mark.asyncio
async def test_cov_emitter_subscribe_and_notify(emitter_address: Address) -> None:
    """Subscribe, receive at least one notification, cancel, no more notifications."""
    dev = DeviceObject(
        objectIdentifier=("device", 999_900),
        objectName="cov-emitter-test-client",
        maxApduLengthAccepted=1476,
        segmentationSupported="segmentedBoth",
        vendorIdentifier=0,
    )
    client = NormalApplication(dev, IPv4Address(f"0.0.0.0/32:{CLIENT_PORT}"))

    q: asyncio.Queue[Any] = asyncio.Queue()
    orig = client.do_UnconfirmedCOVNotificationRequest

    async def cap(apdu: UnconfirmedCOVNotificationRequest) -> None:
        await q.put(apdu)
        await orig(apdu)

    client.do_UnconfirmedCOVNotificationRequest = cap  # type: ignore[method-assign]

    proc_id = 7
    monitored = ObjectIdentifier(("analog-value", 1))
    try:
        sub = SubscribeCOVRequest(
            subscriberProcessIdentifier=proc_id,
            monitoredObjectIdentifier=monitored,
            issueConfirmedNotifications=False,
            lifetime=30,
            destination=emitter_address,
        )
        resp = await asyncio.wait_for(client.request(sub), timeout=2.0)
        assert isinstance(resp, SimpleAckPDU)

        apdu = await asyncio.wait_for(q.get(), timeout=2.0)
        assert apdu.monitoredObjectIdentifier == monitored

        cancel = SubscribeCOVRequest(
            subscriberProcessIdentifier=proc_id,
            monitoredObjectIdentifier=monitored,
            destination=emitter_address,
        )
        cresp = await asyncio.wait_for(client.request(cancel), timeout=2.0)
        assert isinstance(cresp, SimpleAckPDU)

        # Drain any in-flight, then assert silence for 2 seconds
        while not q.empty():
            q.get_nowait()
        with contextlib.suppress(asyncio.TimeoutError):
            extra = await asyncio.wait_for(q.get(), timeout=2.0)
            msg = f"unexpected notification after cancel: {extra!r}"
            raise AssertionError(msg)
    finally:
        client.close()
        await asyncio.sleep(0.05)
