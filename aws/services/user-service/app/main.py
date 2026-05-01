"""
User Service
============
Manages user authentication, profiles, and API keys.

Textbook Reference:
- Ch. 3: Self-service developer experience
- Ch. 5: Security in the pipeline
"""

import os
import secrets
import hashlib
import logging
from datetime import datetime, timedelta
from typing import Optional
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Depends, Header
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer, HTTPAuthorizationCredentials
from pydantic import BaseModel, EmailStr, Field

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

security = HTTPBearer(auto_error=False)


# =============================================================================
# Data Models
# =============================================================================

class User(BaseModel):
    id: str
    email: str
    name: str
    role: str = "user"  # user, developer, admin
    created_at: datetime = Field(default_factory=datetime.utcnow)
    preferences: dict = Field(default_factory=dict)


class UserCreate(BaseModel):
    email: EmailStr
    name: str
    password: str


class UserLogin(BaseModel):
    email: EmailStr
    password: str


class APIKey(BaseModel):
    id: str
    user_id: str
    name: str
    key_hash: str  # We store hash, not the actual key
    prefix: str    # First 8 chars for identification
    scopes: list[str] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=datetime.utcnow)
    last_used: Optional[datetime] = None
    expires_at: Optional[datetime] = None


class APIKeyCreate(BaseModel):
    name: str
    scopes: list[str] = Field(default=["read"])
    expires_in_days: Optional[int] = 90


class Session(BaseModel):
    token: str
    user_id: str
    created_at: datetime = Field(default_factory=datetime.utcnow)
    expires_at: datetime


# =============================================================================
# In-Memory Storage
# =============================================================================

users_db: dict[str, User] = {}
passwords_db: dict[str, str] = {}  # user_id -> hashed password
api_keys_db: dict[str, APIKey] = {}
sessions_db: dict[str, Session] = {}

# Create demo user
demo_user = User(
    id="user-0001",
    email="demo@smarthome.local",
    name="Demo User",
    role="developer"
)
users_db[demo_user.id] = demo_user
passwords_db[demo_user.id] = hashlib.sha256("demo123".encode()).hexdigest()


# =============================================================================
# Helpers
# =============================================================================

def hash_password(password: str) -> str:
    return hashlib.sha256(password.encode()).hexdigest()


def generate_api_key() -> str:
    return f"shk_{secrets.token_urlsafe(32)}"


def hash_api_key(key: str) -> str:
    return hashlib.sha256(key.encode()).hexdigest()


async def get_current_user(
    credentials: HTTPAuthorizationCredentials = Depends(security),
    x_api_key: Optional[str] = Header(None)
) -> Optional[User]:
    """Authenticate via Bearer token or API key."""
    
    # Try API key first
    if x_api_key:
        key_hash = hash_api_key(x_api_key)
        for api_key in api_keys_db.values():
            if api_key.key_hash == key_hash:
                if api_key.expires_at and api_key.expires_at < datetime.utcnow():
                    raise HTTPException(status_code=401, detail="API key expired")
                api_key.last_used = datetime.utcnow()
                return users_db.get(api_key.user_id)
    
    # Try Bearer token
    if credentials:
        session = sessions_db.get(credentials.credentials)
        if session and session.expires_at > datetime.utcnow():
            return users_db.get(session.user_id)
    
    return None


def require_auth(user: Optional[User] = Depends(get_current_user)) -> User:
    if not user:
        raise HTTPException(status_code=401, detail="Authentication required")
    return user


# =============================================================================
# Application
# =============================================================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("User Service starting...")
    yield
    logger.info("User Service shutting down...")


app = FastAPI(
    title="User Service",
    description="User authentication and API key management",
    version="1.0.0",
    lifespan=lifespan
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
async def info():
    return {
        "service": "user-service",
        "users": len(users_db),
        "api_keys": len(api_keys_db),
        "active_sessions": len([s for s in sessions_db.values() if s.expires_at > datetime.utcnow()])
    }


# Authentication
@app.post("/api/v1/user/register", tags=["Auth"], status_code=201)
async def register(user_create: UserCreate):
    """Register a new user."""
    # Check if email exists
    if any(u.email == user_create.email for u in users_db.values()):
        raise HTTPException(status_code=400, detail="Email already registered")
    
    user_id = f"user-{len(users_db) + 1:04d}"
    user = User(
        id=user_id,
        email=user_create.email,
        name=user_create.name
    )
    
    users_db[user_id] = user
    passwords_db[user_id] = hash_password(user_create.password)
    
    logger.info(f"Registered user: {user_id}")
    return {"user": user, "message": "Registration successful"}


@app.post("/api/v1/user/login", tags=["Auth"])
async def login(credentials: UserLogin):
    """Login and get session token."""
    user = None
    for u in users_db.values():
        if u.email == credentials.email:
            user = u
            break
    
    if not user:
        raise HTTPException(status_code=401, detail="Invalid credentials")
    
    if passwords_db.get(user.id) != hash_password(credentials.password):
        raise HTTPException(status_code=401, detail="Invalid credentials")
    
    # Create session
    token = secrets.token_urlsafe(32)
    session = Session(
        token=token,
        user_id=user.id,
        expires_at=datetime.utcnow() + timedelta(hours=24)
    )
    sessions_db[token] = session
    
    return {
        "token": token,
        "user": user,
        "expires_at": session.expires_at
    }


@app.post("/api/v1/user/logout", tags=["Auth"])
async def logout(user: User = Depends(require_auth), credentials: HTTPAuthorizationCredentials = Depends(security)):
    """Logout and invalidate session."""
    if credentials and credentials.credentials in sessions_db:
        sessions_db.pop(credentials.credentials)
    return {"message": "Logged out"}


# Profile
@app.get("/api/v1/user/me", tags=["Profile"])
async def get_profile(user: User = Depends(require_auth)):
    """Get current user profile."""
    return user


@app.put("/api/v1/user/me", tags=["Profile"])
async def update_profile(updates: dict, user: User = Depends(require_auth)):
    """Update user profile."""
    if "name" in updates:
        user.name = updates["name"]
    if "preferences" in updates:
        user.preferences.update(updates["preferences"])
    return user


# API Keys (Self-Service Developer Experience)
@app.get("/api/v1/user/api-keys", tags=["API Keys"])
async def list_api_keys(user: User = Depends(require_auth)):
    """
    List user's API keys.
    
    Textbook Reference: Ch. 3 - Self-service API access
    """
    keys = [k for k in api_keys_db.values() if k.user_id == user.id]
    # Don't return the actual key hash
    return {"api_keys": [
        {
            "id": k.id,
            "name": k.name,
            "prefix": k.prefix,
            "scopes": k.scopes,
            "created_at": k.created_at,
            "last_used": k.last_used,
            "expires_at": k.expires_at
        } for k in keys
    ]}


@app.post("/api/v1/user/api-keys", tags=["API Keys"], status_code=201)
async def create_api_key(key_create: APIKeyCreate, user: User = Depends(require_auth)):
    """
    Create a new API key.
    
    Returns the full key ONCE - it cannot be retrieved again.
    """
    key_id = f"key-{len(api_keys_db) + 1:04d}"
    raw_key = generate_api_key()
    
    expires_at = None
    if key_create.expires_in_days:
        expires_at = datetime.utcnow() + timedelta(days=key_create.expires_in_days)
    
    api_key = APIKey(
        id=key_id,
        user_id=user.id,
        name=key_create.name,
        key_hash=hash_api_key(raw_key),
        prefix=raw_key[:12],
        scopes=key_create.scopes,
        expires_at=expires_at
    )
    
    api_keys_db[key_id] = api_key
    logger.info(f"Created API key {key_id} for user {user.id}")
    
    return {
        "id": key_id,
        "key": raw_key,  # Only returned once!
        "prefix": api_key.prefix,
        "name": api_key.name,
        "scopes": api_key.scopes,
        "expires_at": expires_at,
        "warning": "Save this key! It cannot be retrieved again."
    }


@app.delete("/api/v1/user/api-keys/{key_id}", tags=["API Keys"])
async def revoke_api_key(key_id: str, user: User = Depends(require_auth)):
    """Revoke an API key."""
    if key_id not in api_keys_db:
        raise HTTPException(status_code=404, detail="API key not found")
    
    key = api_keys_db[key_id]
    if key.user_id != user.id:
        raise HTTPException(status_code=403, detail="Not your API key")
    
    api_keys_db.pop(key_id)
    return {"message": f"API key {key_id} revoked"}


# User Preferences
@app.get("/api/v1/user/preferences", tags=["Preferences"])
async def get_preferences(user: User = Depends(require_auth)):
    return {"preferences": user.preferences}


@app.put("/api/v1/user/preferences", tags=["Preferences"])
async def update_preferences(preferences: dict, user: User = Depends(require_auth)):
    user.preferences.update(preferences)
    return {"preferences": user.preferences}


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8003)
