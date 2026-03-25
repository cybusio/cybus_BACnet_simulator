"""BACnet simulator entry point.

Reads configuration from environment variables, loads device profiles,
starts the Prometheus metrics HTTP server, and runs the asyncio event loop
with real BACnet/IP UDP sockets until SIGTERM or SIGINT.
"""

from __future__ import annotations

import asyncio
import logging
import os
import resource
import signal
from http.server import BaseHTTPRequestHandler
from http.server import HTTPServer
from pathlib import Path
from threading import Thread
from typing import Any

from bacnet_sim.devices import DeviceManager
from bacnet_sim.network import BACnetNetwork
from bacnet_sim.profiles import ProfileLoader

logger = logging.getLogger("bacnet_sim")


def _configure_logging(log_format: str, level: str) -> None:
    if log_format == "json":
        fmt = '{"time":"%(asctime)s","level":"%(levelname)s","msg":"%(message)s"}'
    else:
        fmt = "[%(asctime)s] [%(levelname)s] %(message)s"
    logging.basicConfig(format=fmt, level=getattr(logging, level.upper(), logging.INFO))


# ---------------------------------------------------------------------------
# Minimal metrics HTTP server
# ---------------------------------------------------------------------------


class _MetricsHandler(BaseHTTPRequestHandler):
    """Serves /metrics with device count and process RSS."""

    devices_total: int = 0

    def do_GET(self) -> None:
        if self.path == "/metrics":
            rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss * 1024
            body = (
                f"# TYPE bacnet_sim_devices_total gauge\n"
                f"bacnet_sim_devices_total {self.devices_total}\n"
                f"# TYPE bacnet_sim_process_rss_bytes gauge\n"
                f"bacnet_sim_process_rss_bytes {rss}\n"
            ).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/plain; version=0.0.4")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, fmt: str, *args: Any) -> None:  # noqa: ANN401
        _ = fmt, args


def _start_metrics_server(port: int, devices_total: int) -> None:
    _MetricsHandler.devices_total = devices_total
    server = HTTPServer(("0.0.0.0", port), _MetricsHandler)  # noqa: S104
    Thread(target=server.serve_forever, daemon=True).start()
    logger.info("Metrics server on :%d/metrics", port)


# ---------------------------------------------------------------------------
# Async main
# ---------------------------------------------------------------------------


async def _async_main(
    manager: DeviceManager,
    bacnet_port: int,
    bind_address: str,
) -> None:
    network = BACnetNetwork(manager)
    await network.start(base_port=bacnet_port, bind_address=bind_address)

    for device_id, port in sorted(network.port_map().items()):
        logger.info("  Device %d -> UDP %s:%d", device_id, bind_address, port)

    stop_event = asyncio.Event()
    loop = asyncio.get_running_loop()
    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, stop_event.set)

    await stop_event.wait()
    logger.info("Shutting down...")
    await network.stop()


def main() -> None:
    """Run the BACnet simulator."""
    log_format = os.environ.get("BACNET_LOG_FORMAT", "text")
    log_level = os.environ.get("BACNET_LOG_LEVEL", "INFO")
    _configure_logging(log_format, log_level)

    profiles_dir = Path(os.environ.get("BACNET_PROFILES_DIR", "profiles"))
    base_device_id = int(os.environ.get("BACNET_BASE_DEVICE_ID", "100"))
    metrics_port = int(os.environ.get("BACNET_METRICS_PORT", "9100"))
    bacnet_port = int(os.environ.get("BACNET_PORT", "47808"))
    bind_address = os.environ.get("BACNET_BIND_ADDRESS", "0.0.0.0")  # noqa: S104

    object_padding = int(os.environ.get("BACNET_OBJECT_PADDING", "0"))

    loader = ProfileLoader(profiles_dir, object_padding_override=object_padding)
    manager = DeviceManager()
    manager.load_from_profiles(loader, base_device_id=base_device_id)

    logger.info("Loaded %d virtual devices from %s", len(manager), profiles_dir)
    _start_metrics_server(metrics_port, len(manager))

    asyncio.run(_async_main(manager, bacnet_port, bind_address))


if __name__ == "__main__":
    main()
