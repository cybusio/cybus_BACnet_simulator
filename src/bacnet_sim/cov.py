"""Value drivers that nudge presentValue to trigger COV notifications.

Subscribe-COV server logic, subscription registry, and notification dispatch
all live in bacpypes3 (`bacpypes3.service.cov.ChangeOfValueServices`). What
bacpypes3 *cannot* do is generate value motion on its own — real devices get
that from sensors. We supply it here.

SRP boundaries:
    * ValueDriver  — one object, one drive pattern, one tick().
    * DriverRegistry — owns the asyncio task, ticks every driver each cycle.

We deliberately keep both classes ignorant of BACnet semantics; they manipulate
bacpypes3 object attributes via name and let the framework's property setters
trigger COV detection.
"""

from __future__ import annotations

import asyncio
import logging
import math
from dataclasses import dataclass
from typing import TYPE_CHECKING
from typing import Any

if TYPE_CHECKING:
    from bacnet_sim.types import DriveSpec

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class ValueDriver:
    """Drives one BACnet object's presentValue per a DriveSpec.

    For analog shapes we mutate a float; for `toggle` we flip between
    `low`/`high` (analog) or "inactive"/"active" (binary).
    """

    obj: Any
    spec: DriveSpec
    _phase: float = 0.0

    def tick(self) -> None:
        """Advance the driver one step and write the new presentValue."""
        shape = self.spec.shape
        if shape == "sawtooth":
            self._tick_sawtooth()
        elif shape == "sine":
            self._tick_sine()
        elif shape == "toggle":
            self._tick_toggle()

    def _tick_sawtooth(self) -> None:
        new = (self._phase + self.spec.step) % (self.spec.high - self.spec.low + self.spec.step)
        self._phase = new
        self.obj.presentValue = round(self.spec.low + new, 3)

    def _tick_sine(self) -> None:
        self._phase += 0.2
        span = (self.spec.high - self.spec.low) / 2.0
        mid = (self.spec.high + self.spec.low) / 2.0
        self.obj.presentValue = round(mid + span * math.sin(self._phase), 3)

    def _tick_toggle(self) -> None:
        oid_type = str(self.obj.objectIdentifier[0])
        if oid_type.startswith("binary"):
            current_str = str(getattr(self.obj, "presentValue", "inactive"))
            self.obj.presentValue = "inactive" if current_str == "active" else "active"
            return
        # analog or multistate fallback: alternate between low and high
        current_val = float(getattr(self.obj, "presentValue", self.spec.low))
        self.obj.presentValue = self.spec.high if current_val == self.spec.low else self.spec.low


class DriverRegistry:
    """Owns the asyncio task that ticks all registered drivers.

    Period is the minimum non-zero `period_ms` across drivers (capped at 100ms
    floor so tests stay snappy and the loop isn't starved).
    """

    __slots__ = ("_drivers", "_period_s", "_task")

    def __init__(self) -> None:
        self._drivers: list[ValueDriver] = []
        self._task: asyncio.Task[None] | None = None
        self._period_s: float = 0.5

    def add(self, obj: Any, spec: DriveSpec) -> None:  # noqa: ANN401
        """Register a driver for an object."""
        self._drivers.append(ValueDriver(obj=obj, spec=spec))
        # Sync the loop period to the fastest registered driver
        fastest_ms = min((d.spec.period_ms for d in self._drivers), default=500)
        self._period_s = max(fastest_ms, 50) / 1000.0

    def start(self) -> None:
        """Kick off the background loop. No-op if no drivers registered."""
        if not self._drivers or self._task is not None:
            return
        self._task = asyncio.create_task(self._run())

    def stop(self) -> None:
        """Cancel the background loop."""
        if self._task is not None:
            self._task.cancel()
            self._task = None

    async def _run(self) -> None:
        try:
            while True:
                await asyncio.sleep(self._period_s)
                for drv in self._drivers:
                    try:
                        drv.tick()
                    except Exception:
                        logger.exception("driver tick failed for %r", drv.obj.objectIdentifier)
        except asyncio.CancelledError:
            return
