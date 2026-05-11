"""
User Service
============
Manages user authentication, profiles, and API keys.

Storage: Postgres via SQLModel (async). Sessions are stateless JWTs.
"""

import os
import uuid
import socket
import secrets
import hashlib
import logging
from datetime import datetime, timedelta
from typing import Optional
from contextlib import asynccontextmanager

import jwt
from fastapi import FastAPI, HTTPException, Depends, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr
from sqlalchemy import Column, text
from sqlalchemy.dialects.postgresql import JSONB, insert as pg_insert
from sqlalchemy.ext.asyncio import AsyncSession
from sqlmodel import Field, SQLModel, select

from .db import async_session, engine, get_session, init_db

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

JWT_SECRET = os.getenv("JWT_SECRET", "")
JWT_ALG = "HS256"
JWT_TTL_HOURS = 24

security = HTTPBearer(auto_error=False)


# =============================================================================
# Models
# =============================================================================

class UserBase(SQLModel):
    email: str = Field(unique=True, index=True)
    name: str
    role: str = "user"


class User(UserBase, table=True):
    __tablename__ = "users"
    id: str = Field(primary_key=True)
    password_hash: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
    preferences: dict = Field(default_factory=dict, sa_column=Column(JSONB, nullable=False, server_default=text("'{}'::jsonb")))


class UserRead(UserBase):
    id: str
    created_at: datetime
    preferences: dict = Field(default_factory=dict)


class UserCreate(BaseModel):
    email: EmailStr
    name: str
    password: str


class UserLogin(BaseModel):
    email: EmailStr
    password: str


class UserUpdate(BaseModel):
    name: Optional[str] = None
    preferences: Optional[dict] = None


class APIKey(SQLModel, table=True):
    __tablename__ = "api_keys"
    id: str = Field(primary_key=True)
    user_id: str = Field(foreign_key="users.id", index=True)
    name: str
    key_hash: str = Field(index=True)
    prefix: str
    scopes: list = Field(default_factory=list, sa_column=Column(JSONB, nullable=False, server_default=text("'[]'::jsonb")))
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_used: Optional[datetime] = None
    expires_at: Optional[datetime] = None


class APIKeyCreate(BaseModel):
    name: str
    scopes: list[str] = ["read"]
    expires_in_days: Optional[int] = 90


# =============================================================================
# Helpers
# =============================================================================

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()


def hash_api_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


def generate_api_key() -> str:
    return f"shk_{secrets.token_urlsafe(32)}"


def issue_jwt(user_id: str) -> tuple[str, datetime]:
    expires_at = datetime.utcnow() + timedelta(hours=JWT_TTL_HOURS)
    payload = {"sub": user_id, "iat": datetime.utcnow(), "exp": expires_at}
    token = jwt.encode(payload, JWT_SECRET, algorithm=JWT_ALG)
    return token, expires_at


def decode_jwt(token: str) -> Optional[str]:
    try:
        payload = jwt.decode(token, JWT_SECRET, algorithms=[JWT_ALG])
        return payload.get("sub")
    except jwt.ExpiredSignatureError:
        return None
    except jwt.InvalidTokenError:
        return None


async def get_current_user(
    credentials: Optional[HTTPAuthorizationCredentials] = Depends(security),
    x_api_key: Optional[str] = Header(None),
    session: AsyncSession = Depends(get_session),
) -> Optional[User]:
    """Authenticate via Bearer JWT or X-API-Key header."""

    if x_api_key:
        key_hash = hash_api_key(x_api_key)
        result = await session.execute(select(APIKey).where(APIKey.key_hash == key_hash))
        api_key = result.scalar_one_or_none()
        if api_key:
            if api_key.expires_at and api_key.expires_at < datetime.utcnow():
                raise HTTPException(status_code=401, detail="API key expired")
            api_key.last_used = datetime.utcnow()
            session.add(api_key)
            await session.commit()
            user = await session.get(User, api_key.user_id)
            if user:
                return user

    if credentials:
        user_id = decode_jwt(credentials.credentials)
        if user_id:
            user = await session.get(User, user_id)
            if user:
                return user

    return None


def require_auth(user: Optional[User] = Depends(get_current_user)) -> User:
    if not user:
        raise HTTPException(status_code=401, detail="Authentication required")
    return user


async def seed_demo_user() -> None:
    """Ensure the demo user exists with current values. Upserts so a stale
    email from an earlier seed gets fixed on next startup."""
    async with async_session() as session:
        demo_email = "john.doe@example.com"
        stmt = pg_insert(User).values(
            id="user-0001",
            email=demo_email,
            name="Demo User",
            role="developer",
            password_hash=hash_password("demo123"),
            preferences={},
        ).on_conflict_do_update(
            index_elements=["id"],
            set_={
                "email": demo_email,
                "name": "Demo User",
                "role": "developer",
                "password_hash": hash_password("demo123"),
            },
        )
        await session.execute(stmt)
        await session.commit()


# =============================================================================
# Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("User Service starting...")
    if not JWT_SECRET:
        raise RuntimeError("JWT_SECRET env var is required")
    await init_db()
    await seed_demo_user()
    yield
    await engine.dispose()
    logger.info("User Service shutting down...")


app = FastAPI(
    title="User Service",
    description="User authentication and API key management",
    version="2.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)


# =============================================================================
# Endpoints
# =============================================================================

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "user-service"}


@app.get("/api/v1/user/info")
async def info(session: AsyncSession = Depends(get_session)):
    users = (await session.execute(select(User))).scalars().all()
    keys = (await session.execute(select(APIKey))).scalars().all()
    return {
        "service": "user-service",
        "instance": socket.gethostname(),
        "users": len(users),
        "api_keys": len(keys),
    }


# Authentication
@app.post("/api/v1/user/register", tags=["Auth"], status_code=201)
async def register(user_create: UserCreate, session: AsyncSession = Depends(get_session)):
    existing = await session.execute(select(User).where(User.email == user_create.email))
    if existing.scalar_one_or_none():
        raise HTTPException(status_code=400, detail="Email already registered")

    user_id = f"user-{uuid.uuid4().hex[:8]}"

    user = User(
        id=user_id,
        email=user_create.email,
        name=user_create.name,
        password_hash=hash_password(user_create.password),
    )
    session.add(user)
    await session.commit()
    await session.refresh(user)

    return {"user": UserRead.model_validate(user, from_attributes=True), "message": "Registration successful"}


@app.post("/api/v1/user/login", tags=["Auth"])
async def login(credentials: UserLogin, session: AsyncSession = Depends(get_session)):
    result = await session.execute(select(User).where(User.email == credentials.email))
    user = result.scalar_one_or_none()
    if not user or user.password_hash != hash_password(credentials.password):
        raise HTTPException(status_code=401, detail="Invalid credentials")

    token, expires_at = issue_jwt(user.id)
    return {
        "token": token,
        "user": UserRead.model_validate(user, from_attributes=True),
        "expires_at": expires_at,
    }


@app.post("/api/v1/user/logout", tags=["Auth"])
async def logout(user: User = Depends(require_auth)):
    """Stateless JWT — client should discard the token. Server keeps no session state."""
    return {"message": "Logged out"}


# Profile
@app.get("/api/v1/user/me", tags=["Profile"])
async def get_profile(user: User = Depends(require_auth)):
    return UserRead.model_validate(user, from_attributes=True)


@app.put("/api/v1/user/me", tags=["Profile"])
async def update_profile(
    updates: UserUpdate,
    user: User = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
):
    if updates.name is not None:
        user.name = updates.name
    if updates.preferences is not None:
        merged = dict(user.preferences or {})
        merged.update(updates.preferences)
        user.preferences = merged
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return UserRead.model_validate(user, from_attributes=True)


# API Keys
@app.get("/api/v1/user/api-keys", tags=["API Keys"])
async def list_api_keys(
    user: User = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
):
    result = await session.execute(select(APIKey).where(APIKey.user_id == user.id))
    keys = result.scalars().all()
    return {"api_keys": [
        {
            "id": k.id,
            "name": k.name,
            "prefix": k.prefix,
            "scopes": k.scopes,
            "created_at": k.created_at,
            "last_used": k.last_used,
            "expires_at": k.expires_at,
        }
        for k in keys
    ]}


@app.post("/api/v1/user/api-keys", tags=["API Keys"], status_code=201)
async def create_api_key(
    key_create: APIKeyCreate,
    user: User = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
):
    raw_key = generate_api_key()

    expires_at = None
    if key_create.expires_in_days:
        expires_at = datetime.utcnow() + timedelta(days=key_create.expires_in_days)

    key_id = f"key-{uuid.uuid4().hex[:8]}"

    api_key = APIKey(
        id=key_id,
        user_id=user.id,
        name=key_create.name,
        key_hash=hash_api_key(raw_key),
        prefix=raw_key[:12],
        scopes=key_create.scopes,
        expires_at=expires_at,
    )
    session.add(api_key)
    await session.commit()

    return {
        "id": key_id,
        "key": raw_key,
        "prefix": api_key.prefix,
        "name": api_key.name,
        "scopes": api_key.scopes,
        "expires_at": expires_at,
        "warning": "Save this key! It cannot be retrieved again.",
    }


@app.delete("/api/v1/user/api-keys/{key_id}", tags=["API Keys"])
async def revoke_api_key(
    key_id: str,
    user: User = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
):
    api_key = await session.get(APIKey, key_id)
    if not api_key:
        raise HTTPException(status_code=404, detail="API key not found")
    if api_key.user_id != user.id:
        raise HTTPException(status_code=403, detail="Not your API key")
    await session.delete(api_key)
    await session.commit()
    return {"message": f"API key {key_id} revoked"}


# Preferences
@app.get("/api/v1/user/preferences", tags=["Preferences"])
async def get_preferences(user: User = Depends(require_auth)):
    return {"preferences": user.preferences}


@app.put("/api/v1/user/preferences", tags=["Preferences"])
async def update_preferences(
    preferences: dict,
    user: User = Depends(require_auth),
    session: AsyncSession = Depends(get_session),
):
    merged = dict(user.preferences or {})
    merged.update(preferences)
    user.preferences = merged
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return {"preferences": user.preferences}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8003)
