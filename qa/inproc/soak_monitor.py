"""Phase 6 soak monitor — 30 min MQTT collection under 50% packet loss.

Subscribes to services/# for SOAK_MINUTES (default 30) minutes, records
per-topic timestamps, then prints per-device orphan/gap analysis for the
canonical legacy + miele devices.

Exit status: 0 if no legacy IID is silent (orphan==0), 1 otherwise.
"""

from __future__ import annotations

import os
import sys
import time
from typing import Any

import paho.mqtt.client as mqtt
from device_profiles import ALL_DEVICES
from device_profiles import mqtt_prefix

CW_HOST = os.environ.get("CW_HOST", "localhost")
CW_MQTT_PORT = int(os.environ.get("CW_MQTT_PORT", "1883"))
CW_MQTT_USER = os.environ.get("CW_MQTT_USER", "admin")
CW_MQTT_PASS = os.environ.get("CW_MQTT_PASS", "admin")
DURATION = float(os.environ.get("SOAK_MINUTES", "30")) * 60


def main() -> int:
    received: dict[str, list[float]] = {}

    def on_connect(c: Any, _u: Any, _f: Any, _rc: Any, _p: Any = None) -> None:
        c.subscribe("services/#")

    def on_message(_c: Any, _u: Any, msg: mqtt.MQTTMessage) -> None:
        if msg.retain:
            return
        received.setdefault(msg.topic, []).append(time.time())

    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2)  # type: ignore[attr-defined]
    client.username_pw_set(CW_MQTT_USER, CW_MQTT_PASS)
    client.on_connect = on_connect
    client.on_message = on_message
    client.connect(CW_HOST, CW_MQTT_PORT, keepalive=60)
    client.loop_start()

    started = time.time()
    print(f"Soak started: {DURATION / 60:.0f} min, host={CW_HOST}")
    time.sleep(DURATION)
    client.loop_stop()
    client.disconnect()
    elapsed = time.time() - started

    print(f"\nSoak complete: {elapsed:.0f}s, {len(received)} unique topics seen")
    print("=" * 70)

    fail = 0
    # Per-device per-IID check focused on legacy (the RDR's canonical device)
    for key in ("legacy", "miele", "modern", "energy", "newlift", "abort_seg", "no_rpm"):
        dev = ALL_DEVICES[key]
        prefix = mqtt_prefix(dev.scf_name)
        silent, present = [], []
        for obj in dev.objects:
            topic = f"{prefix}/{obj.topic}"
            hits = len(received.get(topic, []))
            if hits == 0:
                silent.append(obj.topic)
            else:
                present.append((obj.topic, hits))

        orphan_count = len(silent)
        total = len(dev.objects)
        avg_hits = sum(h for _, h in present) / len(present) if present else 0.0
        status = "OK" if orphan_count == 0 else "FAIL"
        print(
            f"[{status}] {key:>12}: {total - orphan_count}/{total} endpoints, "
            f"orphans={orphan_count}, avg msgs/endpoint={avg_hits:.0f}"
        )
        if silent:
            print(f"        silent IIDs: {silent}")
        # Legacy is the RDR's canonical acceptance target
        if key == "legacy" and orphan_count > 0:
            fail = 1

    return fail


if __name__ == "__main__":
    sys.exit(main())
