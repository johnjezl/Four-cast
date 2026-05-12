# =============================================================================
# Cloud abstraction — base types and protocols
# =============================================================================
# Service code talks to event buses and secret stores through the
# interfaces defined here. Concrete adapters (aws.py / gcp.py) implement
# them against boto3 and google-cloud-* respectively, and the
# package-level factories in __init__.py pick the right one at runtime
# based on the CLOUD_PROVIDER env var.
# =============================================================================

from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass(frozen=True)
class IncomingEvent:
    """One event pulled from the bus.

    `id` is the cloud-native message identifier (SQS MessageId or
    Pub/Sub message_id) — stable across redeliveries, suitable as an
    idempotency key.

    `ack_token` is opaque to callers; pass it to EventBus.ack() to mark
    the message handled. Don't try to interpret it.
    """

    id: str
    body: dict
    ack_token: str


class EventBus(ABC):
    """Cloud-agnostic event publish/consume.

    SQS collapses topic and subscription into one queue URL; Pub/Sub
    keeps them separate. Service code shouldn't care — each instance is
    bound at construction to whatever the cloud-specific env vars
    indicate. If the relevant env var isn't set (e.g. local dev without
    a queue), the methods become quiet no-ops so callers can keep
    serving read endpoints.
    """

    @abstractmethod
    async def publish(
        self, body: dict, attributes: dict[str, str] | None = None
    ) -> None:
        """Publish one event. `body` must be json-serialisable."""

    @abstractmethod
    async def receive(
        self, max_messages: int = 10, wait_seconds: int = 10
    ) -> list[IncomingEvent]:
        """Long-poll for up to max_messages events.

        Returns [] on timeout or when not configured (sleeps wait_seconds
        in the latter case so the caller's loop doesn't spin hot).
        """

    @abstractmethod
    async def ack(self, ack_token: str) -> None:
        """Acknowledge a handled message. Failure is non-fatal — the
        message will resurface after the visibility timeout / ack
        deadline and the caller is expected to be idempotent."""


class SecretStore(ABC):
    """Cloud-agnostic secret reader.

    Returns the raw secret value as a string; the caller parses (e.g.
    json.loads for a JSON-encoded credential blob).
    """

    @abstractmethod
    def get(self, name: str) -> str: ...
