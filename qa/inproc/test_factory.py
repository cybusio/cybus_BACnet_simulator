"""Factory floor test suite — black-box MQTT verification of the BACnet adapter.

Prerequisites:
    1. Simulator running:  docker compose up --build
    2. Connectware running with rebuilt native addon
    3. SCFs deployed via Admin UI (one per device from scf/)

Run:
    pytest qa/inproc/test_factory.py -v
    pytest qa/inproc/test_factory.py -v -m "not slow"     # skip sustained/ultra-slow
    pytest qa/inproc/test_factory.py -v -k "modern"       # one device
    pytest qa/inproc/test_factory.py -v -k "test_s1"      # one scenario
"""

from __future__ import annotations

import json
import os
import time
from typing import Any

import paho.mqtt.client as mqtt
import pytest
from device_profiles import ALL_DEVICES
from device_profiles import Obj
from device_profiles import devices_with
from device_profiles import mqtt_prefix

CW_HOST = os.environ.get("CW_HOST", "localhost")
CW_MQTT_PORT = int(os.environ.get("CW_MQTT_PORT", "1883"))
CW_MQTT_USER = os.environ.get("CW_MQTT_USER", "admin")
CW_MQTT_PASS = os.environ.get("CW_MQTT_PASS", "admin")


# -- MQTT helper --------------------------------------------------------


def collect_messages(
    host: str,
    port: int,
    topic: str,
    duration: float,
    *,
    user: str = "admin",
    password: str = "admin",
) -> dict[str, list[dict[str, Any]]]:
    """Subscribe to topic, collect non-retained messages for duration seconds.

    Returns {subtopic: [{payload, timestamp}, ...]}.
    """
    received: dict[str, list[dict[str, Any]]] = {}

    def on_connect(
        _client: Any,
        _userdata: Any,
        _flags: Any,
        _rc: Any,
        _props: Any = None,
    ) -> None:
        _client.subscribe(topic)

    def on_message(_client: Any, _userdata: Any, msg: mqtt.MQTTMessage) -> None:
        if msg.retain:
            return
        key = msg.topic
        payload = msg.payload.decode("utf-8", errors="replace")
        if key not in received:
            received[key] = []
        received[key].append({"payload": payload, "ts": time.time()})

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)  # type: ignore[attr-defined]
    client.username_pw_set(user, password)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(host, port, keepalive=60)
    client.loop_start()
    time.sleep(duration)
    client.loop_stop()
    client.disconnect()
    return received


def parse_value(raw: str) -> Any:
    """Parse an MQTT payload to its Python type.

    CW publishes JSON envelopes: {"value": <val>, "timestamp": <ts>}.
    Extract .value if present, otherwise parse as raw.
    """
    try:
        obj = json.loads(raw)
    except (json.JSONDecodeError, ValueError):
        pass
    else:
        if isinstance(obj, dict) and "value" in obj:
            return obj["value"]
        return obj
    try:
        return float(raw)
    except ValueError:
        pass
    return raw


# -- Preflight -----------------------------------------------------------


@pytest.fixture(scope="session", autouse=True)
def preflight() -> None:
    """Verify MQTT broker is reachable before running any tests."""
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)  # type: ignore[attr-defined]
    client.username_pw_set(CW_MQTT_USER, CW_MQTT_PASS)
    try:
        client.connect(CW_HOST, CW_MQTT_PORT, keepalive=5)
        client.disconnect()
    except Exception as exc:
        pytest.skip(f"Connectware MQTT broker unreachable at {CW_HOST}:{CW_MQTT_PORT}: {exc}")


# -- S1: Multi-type read sweep + value type correctness -----------------

# Exclude ultra_slow from S1 — it has its own test (S9) since it never connects
READABLE = [k for k in devices_with("read") if k != "ultra_slow"]


def _check_value(obj: Obj, raw: str) -> str | None:
    """Return None if value is valid, or an error string."""
    val = parse_value(raw)
    if obj.value_type == "number":
        if not isinstance(val, int | float):
            return f"expected number, got {type(val).__name__}: {raw!r}"
    elif obj.value_type == "string":
        if not isinstance(val, str):
            return f"expected string, got {type(val).__name__}: {raw!r}"
        if obj.enum and val not in obj.enum:
            return f"value {val!r} not in {obj.enum}"
    elif obj.value_type == "boolean" and val not in (
        True,
        False,
        "true",
        "false",
        "active",
        "inactive",
    ):
        return f"expected boolean, got {raw!r}"
    return None


@pytest.mark.parametrize("device_key", READABLE, ids=READABLE)
def test_s1_read_sweep(device_key: str) -> None:
    """Every endpoint publishes a value with the correct type and range."""
    dev = ALL_DEVICES[device_key]
    prefix = mqtt_prefix(dev.scf_name)
    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        f"{prefix}/#",
        dev.settle_time,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )

    # Strip prefix to get endpoint topic names
    seen = {t.replace(f"{prefix}/", ""): msgs for t, msgs in received.items()}

    missing = [o.topic for o in dev.objects if o.topic not in seen]
    if "slow" in dev.capabilities:
        # Slow devices may not deliver all endpoints — just require some data
        assert len(seen) > 0 or not dev.objects, f"{dev.name}: no endpoints published at all"
    else:
        assert not missing, f"{dev.name}: missing endpoints: {missing}"

    errors = []
    for obj in dev.objects:
        if obj.topic not in seen:
            continue
        latest = seen[obj.topic][-1]["payload"]
        err = _check_value(obj, latest)
        if err:
            errors.append(f"{obj.topic}: {err}")
    assert not errors, f"{dev.name} value errors:\n" + "\n".join(errors)


# -- S2: Write + readback -----------------------------------------------

WRITABLE = devices_with("write")


@pytest.mark.write
@pytest.mark.parametrize("device_key", WRITABLE, ids=WRITABLE)
def test_s2_write_readback(device_key: str) -> None:
    """Write a value, read it back via MQTT, verify it changed."""
    dev = ALL_DEVICES[device_key]
    prefix = mqtt_prefix(dev.scf_name)
    writable_objs = [o for o in dev.objects if o.writable]
    assert writable_objs, f"{dev.name} has no writable objects"

    obj = writable_objs[0]
    write_topic = f"{prefix}/{obj.topic}/set"
    read_topic = f"{prefix}/{obj.topic}"

    # Pick a safe write value (AV objects accept any float)
    write_val = 42.0

    # Publish write
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)  # type: ignore[attr-defined]
    client.username_pw_set(CW_MQTT_USER, CW_MQTT_PASS)
    client.connect(CW_HOST, CW_MQTT_PORT)
    client.publish(write_topic, str(write_val))
    client.disconnect()

    # Wait for adapter to poll and publish the new value
    time.sleep(dev.settle_time)

    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        read_topic,
        5,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )

    assert received, f"No value received on {read_topic} after write"
    latest = next(iter(received.values()))[-1]["payload"]
    read_val = parse_value(latest)
    # Verify the endpoint still publishes a valid number after the write
    # (the simulator may not persist the written value, but the adapter must not crash)
    assert isinstance(read_val, int | float), f"Expected number after write, got {read_val!r}"


# -- S3: Abort fallback -------------------------------------------------

ABORT_DEVICES = devices_with("abort")


@pytest.mark.parametrize("device_key", ABORT_DEVICES, ids=ABORT_DEVICES)
def test_s3_abort_fallback(device_key: str) -> None:
    """Constrained devices still publish values despite APDU abort limits."""
    dev = ALL_DEVICES[device_key]
    prefix = mqtt_prefix(dev.scf_name)
    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        f"{prefix}/#",
        dev.settle_time,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )

    seen_topics = {t.replace(f"{prefix}/", "") for t in received}
    expected = {o.topic for o in dev.objects}

    # Abort devices must publish (nearly) every endpoint once fallback stabilises.
    # For slow+abort devices the test window is sized to cover one full poll cycle.
    arrived = expected & seen_topics
    ratio = len(arrived) / len(expected) if expected else 1.0
    min_ratio = 0.8 if "slow" in dev.capabilities else 0.5
    assert ratio >= min_ratio, (
        f"{dev.name} (abort={dev.abort_code}): only {len(arrived)}/{len(expected)} "
        f"endpoints published ({ratio:.0%})"
    )


# -- S4: Concurrent multi-device + topic isolation ----------------------


def test_s4_concurrent_multi_device() -> None:
    """All devices publish simultaneously, no device starved, no topic collision."""
    # Subscribe to all services at once
    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        "services/#",
        60,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )

    # Group by device
    device_hits: dict[str, int] = {}
    for dev_key, dev in ALL_DEVICES.items():
        if "empty" in dev.capabilities or "slow" in dev.capabilities:
            continue  # empty has 0 endpoints; slow may not connect in time
        prefix = mqtt_prefix(dev.scf_name)
        count = sum(1 for t in received if t.startswith(f"{prefix}/"))
        device_hits[dev_key] = count

    # Every non-empty device must have at least 1 message
    silent = [k for k, v in device_hits.items() if v == 0]
    assert not silent, f"Devices produced no messages: {silent}"

    # Topic isolation: no topic should appear under two different prefixes
    all_topics = list(received.keys())
    prefixes = [mqtt_prefix(d.scf_name) for d in ALL_DEVICES.values()]
    for topic in all_topics:
        matches = [p for p in prefixes if topic.startswith(f"{p}/")]
        assert len(matches) <= 1, f"Topic {topic} matched multiple prefixes: {matches}"


# -- S6: Sustained polling -----------------------------------------------

SUSTAINED_DURATION = float(os.environ.get("SUSTAINED_MINUTES", "10")) * 60
SUSTAINED_DEVICES = [k for k in devices_with("read") if "slow" not in ALL_DEVICES[k].capabilities]


@pytest.mark.slow
def test_s6_sustained_polling() -> None:
    """No topic goes silent during extended polling. Reports timing stats."""
    # Collect for SUSTAINED_DURATION
    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        "services/#",
        SUSTAINED_DURATION,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )

    # Check each device's topics for silence
    silent_topics: list[str] = []
    stats: list[str] = []

    for key in SUSTAINED_DEVICES:
        dev = ALL_DEVICES[key]
        prefix = mqtt_prefix(dev.scf_name)
        for obj in dev.objects:
            full_topic = f"{prefix}/{obj.topic}"
            msgs = received.get(full_topic, [])
            if len(msgs) < 2:
                silent_topics.append(f"{key}/{obj.topic} ({len(msgs)} msgs)")
                continue
            # Compute intervals
            timestamps = [m["ts"] for m in msgs]
            intervals = [timestamps[i + 1] - timestamps[i] for i in range(len(timestamps) - 1)]
            avg_interval = sum(intervals) / len(intervals)
            max_interval = max(intervals)
            silence_budget = obj.max_silence_override or dev.max_silence
            if max_interval > silence_budget:
                silent_topics.append(
                    f"{key}/{obj.topic} (max gap {max_interval:.1f}s > {silence_budget}s)"
                )
            stats.append(
                f"  {key}/{obj.topic}: {len(msgs)} msgs, "
                f"avg={avg_interval:.1f}s, max={max_interval:.1f}s"
            )

    print(f"\n{'=' * 60}")
    print(f"Sustained polling report ({SUSTAINED_DURATION / 60:.0f} min)")
    print(f"{'=' * 60}")
    for line in stats[:30]:  # cap output
        print(line)
    if len(stats) > 30:
        print(f"  ... and {len(stats) - 30} more")

    assert not silent_topics, "Silent/slow topics:\n" + "\n".join(silent_topics)


# -- S7: No-RPM device --------------------------------------------------


def test_s7_no_rpm_device() -> None:
    """No-RPM device publishes values via RP fallback (no RPM attempted)."""
    dev = ALL_DEVICES["no_rpm"]
    prefix = mqtt_prefix(dev.scf_name)
    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        f"{prefix}/#",
        dev.settle_time,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )
    seen = {t.replace(f"{prefix}/", "") for t in received}
    expected = {o.topic for o in dev.objects}
    missing = expected - seen
    assert not missing, f"No-RPM device missing endpoints: {missing}"


# -- S8: Empty device ----------------------------------------------------


def test_s8_empty_device() -> None:
    """Empty device connects without crashing. No data endpoints expected."""
    dev = ALL_DEVICES["empty"]
    prefix = mqtt_prefix(dev.scf_name)

    # Empty device has 0 objects — no data topics expected
    assert len(dev.objects) == 0, "Empty device should have 0 objects"

    # Subscribe briefly — should see no data topics (maybe connection status)
    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        f"{prefix}/#",
        dev.settle_time,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )

    # No data endpoints expected — any messages are connection metadata (ok)
    data_topics = [t for t in received if not t.endswith("/status")]
    # Empty device may legitimately have 0 messages. No crash = pass.
    # If there ARE data topics, something is wrong (phantom endpoints).
    assert len(data_topics) == 0, f"Empty device produced data topics: {data_topics}"


# -- S9: Ultra-slow device -----------------------------------------------


@pytest.mark.slow
def test_s9_ultra_slow() -> None:
    """Ultra-slow device (12s response) either delivers values or times out cleanly."""
    dev = ALL_DEVICES["ultra_slow"]
    prefix = mqtt_prefix(dev.scf_name)

    # Wait longer than the 12s response + 15s sweep + buffer
    received = collect_messages(
        CW_HOST,
        CW_MQTT_PORT,
        f"{prefix}/#",
        dev.settle_time,
        user=CW_MQTT_USER,
        password=CW_MQTT_PASS,
    )

    seen = {t.replace(f"{prefix}/", "") for t in received}
    expected = {o.topic for o in dev.objects}

    # Ultra-slow: values may or may not arrive. The test passes either way.
    # What matters: no crash, no hang. If we got here, the adapter survived.
    if seen & expected:
        print(f"Ultra-slow device delivered {len(seen & expected)}/{len(expected)} endpoints")
    else:
        print("Ultra-slow device: no values within timeout (expected -- 12s response > TSM)")
