# =============================================================================
# Cloud abstraction - Azure adapter
# =============================================================================
# Service Bus-backed ServiceBusEventBus and Key Vault-backed
# KeyVaultSecretStore. The protocol shape matches the AWS and GCP
# adapters so service code remains identical across clouds.
#
# Azure Service Bus uses one queue for this deployment. If either the
# namespace or queue name is unset, methods become quiet no-ops so local
# dev and read-only services keep the same ergonomics as AWS/GCP.
# =============================================================================

from __future__ import annotations

import asyncio
import json
import logging
import os
import uuid
from typing import Optional
from urllib.parse import urlparse

from azure.identity import DefaultAzureCredential
from azure.keyvault.secrets import SecretClient
from azure.servicebus import ServiceBusClient, ServiceBusMessage
from azure.servicebus.exceptions import ServiceBusError

from .base import EventBus, IncomingEvent, SecretStore

logger = logging.getLogger(__name__)


class ServiceBusEventBus(EventBus):
    """Service Bus-backed bus.

    Reads AZURE_SERVICEBUS_FULLY_QUALIFIED_NAMESPACE and SERVICEBUS_QUEUE
    at construction. Terraform sets both for Azure Container Apps. The
    alternate SERVICEBUS_FULLY_QUALIFIED_NAMESPACE and
    SERVICE_BUS_QUEUE_NAME names are accepted for compatibility with
    Azure SDK examples and ad-hoc local runs.
    """

    def __init__(
        self,
        namespace: Optional[str] = None,
        queue_name: Optional[str] = None,
        credential: Optional[DefaultAzureCredential] = None,
    ) -> None:
        self._namespace = namespace or os.environ.get(
            "AZURE_SERVICEBUS_FULLY_QUALIFIED_NAMESPACE",
            os.environ.get("SERVICEBUS_FULLY_QUALIFIED_NAMESPACE", ""),
        )
        self._queue_name = queue_name or os.environ.get(
            "SERVICEBUS_QUEUE",
            os.environ.get("SERVICE_BUS_QUEUE_NAME", ""),
        )
        self._credential = credential or _default_credential()
        self._client: Optional[ServiceBusClient] = None
        self._sender = None
        self._receiver = None
        self._pending: dict[str, object] = {}

    def _ensure_client(self) -> Optional[ServiceBusClient]:
        if not (self._namespace and self._queue_name):
            return None
        if self._client is None:
            self._client = ServiceBusClient(
                fully_qualified_namespace=self._namespace,
                credential=self._credential,
            )
        return self._client

    def _ensure_sender(self):
        client = self._ensure_client()
        if client is None:
            return None
        if self._sender is None:
            self._sender = client.get_queue_sender(queue_name=self._queue_name)
        return self._sender

    def _ensure_receiver(self):
        client = self._ensure_client()
        if client is None:
            return None
        if self._receiver is None:
            self._receiver = client.get_queue_receiver(queue_name=self._queue_name)
        return self._receiver

    async def publish(
        self, body: dict, attributes: dict[str, str] | None = None
    ) -> None:
        sender = self._ensure_sender()
        if sender is None:
            return
        message = ServiceBusMessage(
            json.dumps(body),
            message_id=str(uuid.uuid4()),
            content_type="application/json",
            application_properties={
                key: str(value) for key, value in (attributes or {}).items()
            },
        )
        await asyncio.to_thread(sender.send_messages, message)

    async def receive(
        self, max_messages: int = 10, wait_seconds: int = 10
    ) -> list[IncomingEvent]:
        receiver = self._ensure_receiver()
        if receiver is None:
            await asyncio.sleep(wait_seconds)
            return []
        try:
            messages = await asyncio.to_thread(
                receiver.receive_messages,
                max_message_count=max_messages,
                max_wait_time=wait_seconds,
            )
        except ServiceBusError as e:
            logger.error(f"Service Bus receive failed: {e}")
            await asyncio.sleep(5)
            return []
        except Exception as e:
            logger.error(f"Service Bus receive failed: {e}")
            await asyncio.sleep(5)
            return []

        out: list[IncomingEvent] = []
        for msg in messages:
            try:
                body = json.loads(_message_body_text(msg))
            except (json.JSONDecodeError, UnicodeDecodeError):
                logger.warning(
                    f"Dropping non-JSON Service Bus message {msg.message_id!r}"
                )
                continue

            ack_token = str(msg.lock_token)
            self._pending[ack_token] = msg
            out.append(
                IncomingEvent(
                    id=str(msg.message_id),
                    body=body,
                    ack_token=ack_token,
                )
            )
        return out

    async def ack(self, ack_token: str) -> None:
        receiver = self._ensure_receiver()
        if receiver is None:
            return
        msg = self._pending.pop(ack_token, None)
        if msg is None:
            logger.warning("Service Bus ack skipped: unknown lock token.")
            return
        try:
            await asyncio.to_thread(receiver.complete_message, msg)
        except ServiceBusError as e:
            logger.warning(f"Service Bus complete failed (will re-receive): {e}")
        except Exception as e:
            logger.warning(f"Service Bus complete failed (will re-receive): {e}")


def _message_body_text(message: object) -> str:
    raw_body = getattr(message, "body", None)
    if isinstance(raw_body, str):
        return raw_body
    if isinstance(raw_body, (bytes, bytearray)):
        return bytes(raw_body).decode("utf-8")
    if raw_body is not None:
        try:
            chunks = []
            for chunk in raw_body:
                if isinstance(chunk, (bytes, bytearray)):
                    chunks.append(bytes(chunk))
                else:
                    chunks.append(str(chunk).encode("utf-8"))
            if chunks:
                return b"".join(chunks).decode("utf-8")
        except TypeError:
            pass
    return str(message)


class KeyVaultSecretStore(SecretStore):
    """Key Vault-backed store.

    `name` may be either a short secret name or a full Key Vault secret
    URI. Short names use AZURE_KEY_VAULT_URL, with KEY_VAULT_URL accepted
    as a local-dev alias.
    """

    def __init__(
        self,
        vault_url: Optional[str] = None,
        credential: Optional[DefaultAzureCredential] = None,
    ) -> None:
        self._default_vault_url = vault_url or os.environ.get(
            "AZURE_KEY_VAULT_URL",
            os.environ.get("KEY_VAULT_URL", ""),
        )
        self._credential = credential or _default_credential()
        self._clients: dict[str, SecretClient] = {}

    def _client_for(self, vault_url: str) -> SecretClient:
        if vault_url not in self._clients:
            self._clients[vault_url] = SecretClient(
                vault_url=vault_url,
                credential=self._credential,
            )
        return self._clients[vault_url]

    def get(self, name: str) -> str:
        vault_url, secret_name, version = self._parse_secret_name(name)
        response = self._client_for(vault_url).get_secret(secret_name, version)
        # SDK types response.value as Optional[str]; a null-valued secret
        # would crash downstream callers (json.loads, .encode(), etc.) in
        # confusing ways. Fail loudly here.
        if response.value is None:
            raise RuntimeError(f"Key Vault secret {secret_name!r} has no value.")
        return response.value

    def _parse_secret_name(self, name: str) -> tuple[str, str, str | None]:
        if name.startswith("https://"):
            parsed = urlparse(name)
            path_parts = [part for part in parsed.path.split("/") if part]
            if len(path_parts) < 2 or path_parts[0] != "secrets":
                raise RuntimeError(f"Invalid Key Vault secret URI: {name!r}")
            vault_url = f"{parsed.scheme}://{parsed.netloc}"
            version = path_parts[2] if len(path_parts) > 2 else None
            return vault_url, path_parts[1], version

        if not self._default_vault_url:
            raise RuntimeError(
                "AZURE_KEY_VAULT_URL must be set to look up secrets by short name."
            )
        return self._default_vault_url, name, None


def _default_credential() -> DefaultAzureCredential:
    managed_identity_client_id = os.environ.get("AZURE_CLIENT_ID")
    if managed_identity_client_id:
        return DefaultAzureCredential(
            managed_identity_client_id=managed_identity_client_id
        )
    return DefaultAzureCredential()
