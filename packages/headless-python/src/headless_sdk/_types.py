from __future__ import annotations

import math
from dataclasses import dataclass
from typing import Generic, Protocol, TypeGuard, TypeVar

T = TypeVar("T")


def is_finite_number(value: object) -> TypeGuard[int | float]:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        return False
    try:
        return math.isfinite(value)
    except OverflowError:
        return False


@dataclass(frozen=True, slots=True)
class Untrusted(Generic[T]):
    """A value containing page-derived data that must remain untrusted."""

    value: T
    untrusted_content: bool = True


class SyncCancellation(Protocol):
    def is_set(self) -> bool: ...


class AsyncCancellation(Protocol):
    def is_set(self) -> bool: ...

    async def wait(self) -> bool: ...
