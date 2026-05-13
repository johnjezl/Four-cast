# =============================================================================
# Cloud abstraction — selector
# =============================================================================
# event_bus() and secret_store() pick the right adapter based on the
# CLOUD_PROVIDER env var. The adapter modules are lazy-imported so an
# AWS container doesn't need google-cloud-* or azure-* installed and
# vice versa. Importing this package costs nothing until you call a
# factory.
# =============================================================================

from __future__ import annotations

import os

from .base import EventBus, IncomingEvent, SecretStore


def _provider() -> str:
    value = os.environ.get("CLOUD_PROVIDER")
    if not value:
        raise RuntimeError(
            "CLOUD_PROVIDER environment variable must be set to 'aws', 'gcp', or 'azure'."
        )
    return value.strip().lower()


def event_bus() -> EventBus:
    provider = _provider()
    if provider == "aws":
        from . import aws

        return aws.SqsEventBus()
    if provider == "gcp":
        from . import gcp

        return gcp.PubSubEventBus()
    if provider == "azure":
        from . import azure

        return azure.ServiceBusEventBus()
    raise RuntimeError(f"Unknown CLOUD_PROVIDER: {provider!r}")


def secret_store() -> SecretStore:
    provider = _provider()
    if provider == "aws":
        from . import aws

        return aws.SecretsManagerStore()
    if provider == "gcp":
        from . import gcp

        return gcp.SecretManagerStore()
    if provider == "azure":
        from . import azure

        return azure.KeyVaultSecretStore()
    raise RuntimeError(f"Unknown CLOUD_PROVIDER: {provider!r}")


__all__ = [
    "EventBus",
    "IncomingEvent",
    "SecretStore",
    "event_bus",
    "secret_store",
]
