# =============================================================================
# Cloud abstraction — GCP adapter
# =============================================================================
# Pub/Sub-backed PubSubEventBus and Secret Manager-backed
# SecretManagerStore. The protocol shape matches the AWS adapter (see
# aws.py) so service code is identical.
#
# Pub/Sub keeps topic and subscription distinct: EVENT_TOPIC drives
# publishes, EVENT_SUBSCRIPTION drives receives. Either may be unset
# depending on the service (device-service only publishes, analytics-
# service only consumes); methods become quiet no-ops when their config
# is missing.
# =============================================================================

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import TYPE_CHECKING, Optional

from .base import EventBus, IncomingEvent, SecretStore

if TYPE_CHECKING:
    from google.cloud import pubsub_v1

logger = logging.getLogger(__name__)


# SDK imports are deferred to per-class constructors. Importing this
# module is free — only constructing PubSubEventBus pulls in
# google-cloud-pubsub, and only constructing SecretManagerStore pulls
# in google-cloud-secret-manager. That lets device-service /
# analytics-service ship without google-cloud-secret-manager in their
# requirements.txt, and tuya-bridge ship without google-cloud-pubsub.


class PubSubEventBus(EventBus):
    """Pub/Sub-backed bus.

    EVENT_TOPIC and EVENT_SUBSCRIPTION are short names (not full
    resource paths); GCP_PROJECT supplies the project component.
    Publisher and subscriber clients are constructed lazily so a
    consume-only service doesn't open a publisher socket and vice versa.
    """

    def __init__(self) -> None:
        # Lazy SDK import so containers without google-cloud-pubsub
        # installed can still import shared.cloud.gcp (e.g. tuya-bridge).
        from google.cloud import pubsub_v1

        self._pubsub_v1 = pubsub_v1
        self._project = os.environ.get("GCP_PROJECT", "")
        self._topic = os.environ.get("EVENT_TOPIC", "")
        self._subscription = os.environ.get("EVENT_SUBSCRIPTION", "")
        self._publisher: Optional[pubsub_v1.PublisherClient] = None
        self._subscriber: Optional[pubsub_v1.SubscriberClient] = None

    def _ensure_publisher(self) -> Optional[pubsub_v1.PublisherClient]:
        if not (self._project and self._topic):
            return None
        if self._publisher is None:
            self._publisher = self._pubsub_v1.PublisherClient()
        return self._publisher

    def _ensure_subscriber(self) -> Optional[pubsub_v1.SubscriberClient]:
        if not (self._project and self._subscription):
            return None
        if self._subscriber is None:
            self._subscriber = self._pubsub_v1.SubscriberClient()
        return self._subscriber

    async def publish(
        self, body: dict, attributes: dict[str, str] | None = None
    ) -> None:
        pub = self._ensure_publisher()
        if pub is None:
            return
        topic_path = pub.topic_path(self._project, self._topic)
        # publish() returns a Future immediately (it batches under the
        # hood); .result() blocks until the broker confirms. Run the
        # wait in a thread so the event loop stays free.
        future = pub.publish(
            topic_path,
            json.dumps(body).encode("utf-8"),
            **(attributes or {}),
        )
        await asyncio.to_thread(future.result, 30)

    async def receive(
        self, max_messages: int = 10, wait_seconds: int = 10
    ) -> list[IncomingEvent]:
        from google.api_core.exceptions import DeadlineExceeded

        sub = self._ensure_subscriber()
        if sub is None:
            await asyncio.sleep(wait_seconds)
            return []
        sub_path = sub.subscription_path(self._project, self._subscription)
        try:
            response = await asyncio.to_thread(
                sub.pull,
                request={
                    "subscription": sub_path,
                    "max_messages": max_messages,
                    "return_immediately": False,
                },
                # Generous client-side budget so we don't tear down the
                # gRPC call while the broker is still long-polling.
                timeout=wait_seconds + 5,
            )
        except DeadlineExceeded:
            return []
        except Exception as e:
            # Catch broadly: transient gRPC errors (connection reset,
            # token refresh blip, broker hiccup) must not kill the
            # consumer loop. Caller will retry on the next tick.
            logger.error(f"Pub/Sub pull failed: {e}")
            await asyncio.sleep(5)
            return []

        out: list[IncomingEvent] = []
        for received in response.received_messages:
            msg = received.message
            try:
                body = json.loads(msg.data.decode("utf-8"))
            except (json.JSONDecodeError, UnicodeDecodeError):
                # Adapter drops malformed messages instead of bubbling
                # them up — see the matching note in aws.py. No ack
                # means Pub/Sub redelivers, and dead_letter_policy on
                # the subscription eventually routes to the DLQ.
                logger.warning(
                    f"Dropping non-JSON Pub/Sub message {msg.message_id!r}"
                )
                continue
            out.append(
                IncomingEvent(
                    id=msg.message_id,
                    body=body,
                    ack_token=received.ack_id,
                )
            )
        return out

    async def ack(self, ack_token: str) -> None:
        sub = self._ensure_subscriber()
        if sub is None:
            return
        sub_path = sub.subscription_path(self._project, self._subscription)
        try:
            await asyncio.to_thread(
                sub.acknowledge,
                request={"subscription": sub_path, "ack_ids": [ack_token]},
            )
        except Exception as e:
            # Catch broadly: ack failure is non-fatal — Pub/Sub will
            # resurface the message after the ack deadline, and the
            # consumer's idempotency story (ON CONFLICT DO NOTHING)
            # keeps redeliveries from duplicating rows.
            logger.warning(f"Pub/Sub ack failed (will re-receive): {e}")


class SecretManagerStore(SecretStore):
    """Secret Manager-backed store.

    `name` may be either a short name (e.g. "smarthome-dev-tuya-
    credentials") or a full resource path. Short names use the latest
    version of the secret in the GCP_PROJECT project.
    """

    def __init__(self) -> None:
        # Lazy SDK import so containers without google-cloud-secret-manager
        # installed can still import shared.cloud.gcp (e.g. device-service,
        # analytics-service — only tuya-bridge actually reads secrets).
        from google.cloud import secretmanager

        self._project = os.environ.get("GCP_PROJECT", "")
        self._client = secretmanager.SecretManagerServiceClient()

    def get(self, name: str) -> str:
        if name.startswith("projects/"):
            resource = name
        else:
            if not self._project:
                raise RuntimeError(
                    "GCP_PROJECT must be set to look up secrets by short name."
                )
            resource = f"projects/{self._project}/secrets/{name}/versions/latest"
        response = self._client.access_secret_version(name=resource)
        return response.payload.data.decode("utf-8")
