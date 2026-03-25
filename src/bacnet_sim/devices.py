"""Device manager — loads profiles and provides iteration for BACnetNetwork."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from collections.abc import Iterator

    from bacnet_sim.profiles import ProfileLoader
    from bacnet_sim.types import DeviceProfile


@dataclass(slots=True)
class VirtualDevice:
    """A virtual BACnet device: just a device ID and its profile."""

    device_id: int
    profile: DeviceProfile


class DeviceManager:
    """Loads profiles and yields VirtualDevice instances for the network layer."""

    def __init__(self) -> None:
        self._devices: list[VirtualDevice] = []

    def __len__(self) -> int:
        return len(self._devices)

    def load_from_profiles(
        self,
        loader: ProfileLoader,
        *,
        base_device_id: int,
    ) -> None:
        """Load profiles. Uses simulator.device_id from profile if set, else sequential."""
        self._devices.clear()
        for offset, profile in enumerate(loader.load_all()):
            dev_id = profile.simulator_device_id or (base_device_id + offset)
            self._devices.append(VirtualDevice(dev_id, profile))

    def broadcast(self) -> Iterator[VirtualDevice]:
        """Yield every managed VirtualDevice."""
        yield from self._devices
