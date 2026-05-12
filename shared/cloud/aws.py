# =============================================================================
# Cloud abstraction — AWS adapter
# =============================================================================
# boto3-backed SqsEventBus and SecretsManagerStore. The behavior here
# matches the call-site shapes that lived directly in the services
# before the abstraction landed: SQS long-poll receive with MessageId as
# the stable id, ReceiptHandle as the ack token, and a no-op publish
# when DEVICE_EVENTS_QUEUE isn't set (preserves local-dev ergonomics).
# =============================================================================

from __future__ import annotations

import asyncio
import json
import logging
import os
from typing import Optional

import boto3
from botocore.exceptions import ClientError

from .base import EventBus, IncomingEvent, SecretStore

logger = logging.getLogger(__name__)


class SqsEventBus(EventBus):
    """SQS-backed bus. Topic and subscription are the same queue URL.

    Reads DEVICE_EVENTS_QUEUE and AWS_REGION at construction. If the
    queue URL is empty, the bus is a quiet no-op so a service can still
    serve read endpoints in environments where no queue is provisioned.
    """

    def __init__(
        self,
        queue_url: Optional[str] = None,
        region: Optional[str] = None,
    ) -> None:
        self._queue_url = queue_url or os.environ.get("DEVICE_EVENTS_QUEUE", "")
        self._region = region or os.environ.get("AWS_REGION", "us-east-1")
        self._client = (
            boto3.client("sqs", region_name=self._region) if self._queue_url else None
        )

    async def publish(
        self, body: dict, attributes: dict[str, str] | None = None
    ) -> None:
        if self._client is None:
            return
        msg_attrs = {
            k: {"DataType": "String", "StringValue": v}
            for k, v in (attributes or {}).items()
        }
        await asyncio.to_thread(
            self._client.send_message,
            QueueUrl=self._queue_url,
            MessageBody=json.dumps(body),
            MessageAttributes=msg_attrs,
        )

    async def receive(
        self, max_messages: int = 10, wait_seconds: int = 10
    ) -> list[IncomingEvent]:
        if self._client is None:
            # No queue configured — sleep so the caller's loop doesn't spin.
            await asyncio.sleep(wait_seconds)
            return []
        try:
            resp = await asyncio.to_thread(
                self._client.receive_message,
                QueueUrl=self._queue_url,
                MaxNumberOfMessages=max_messages,
                WaitTimeSeconds=wait_seconds,
            )
        except ClientError as e:
            logger.error(f"SQS receive failed: {e}")
            await asyncio.sleep(5)
            return []

        out: list[IncomingEvent] = []
        for msg in resp.get("Messages", []):
            try:
                body = json.loads(msg["Body"])
            except json.JSONDecodeError:
                # Adapter drops malformed messages instead of bubbling
                # them up. Pre-abstraction this was caught in the
                # consumer's try/except; the net behavior is the same
                # (no ack -> visibility-timeout redeliver -> eventually
                # DLQ after maxReceiveCount) but the log line moved.
                logger.warning(
                    f"Dropping non-JSON SQS message {msg.get('MessageId')!r}"
                )
                continue
            out.append(
                IncomingEvent(
                    id=msg["MessageId"],
                    body=body,
                    ack_token=msg["ReceiptHandle"],
                )
            )
        return out

    async def ack(self, ack_token: str) -> None:
        if self._client is None:
            return
        try:
            await asyncio.to_thread(
                self._client.delete_message,
                QueueUrl=self._queue_url,
                ReceiptHandle=ack_token,
            )
        except ClientError as e:
            # Visibility timeout will resurface the message; the caller's
            # idempotency story is responsible for not double-applying.
            logger.warning(f"SQS delete failed (will re-receive): {e}")


class SecretsManagerStore(SecretStore):
    """Secrets Manager-backed store. `name` is the secret name or ARN."""

    def __init__(self, region: Optional[str] = None) -> None:
        self._region = region or os.environ.get("AWS_REGION", "us-east-1")
        self._client = boto3.client("secretsmanager", region_name=self._region)

    def get(self, name: str) -> str:
        response = self._client.get_secret_value(SecretId=name)
        return response["SecretString"]
