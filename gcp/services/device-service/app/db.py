"""Async Postgres engine, session, and schema bootstrap."""

import os
import logging
from typing import AsyncIterator

from sqlalchemy import text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlmodel import SQLModel

logger = logging.getLogger(__name__)

DATABASE_URL = os.getenv("DATABASE_URL", "")

engine = create_async_engine(
    DATABASE_URL,
    echo=os.getenv("LOG_LEVEL", "INFO").upper() == "DEBUG",
    pool_pre_ping=True,
    pool_size=2,
    max_overflow=3,
)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


async def init_db() -> None:
    async with engine.begin() as conn:
        await conn.run_sync(SQLModel.metadata.create_all)
        # Idempotent column-add for `devices.device_metadata` so
        # existing deployments pick up the new column without needing
        # an out-of-band migration. SQLModel.create_all only creates
        # missing tables — it won't ALTER an existing table to add a
        # column the new model declares. `IF NOT EXISTS` on the column
        # covers fresh deploys where create_all already produced it.
        await conn.execute(text(
            "ALTER TABLE IF EXISTS devices "
            "ADD COLUMN IF NOT EXISTS device_metadata JSONB "
            "NOT NULL DEFAULT '{}'::jsonb"
        ))
    logger.info("Database schema ready")


async def get_session() -> AsyncIterator[AsyncSession]:
    async with async_session() as session:
        yield session
