"""FastAPI entrypoint — localhost-only, CORS off, serial worker on start."""

import asyncio
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from .config import HOST, PORT, enforce_localhost_bind, SERVER_STATE_DIR, LOGS_DIR, TASKS_FILE
from .routers import tasks, metrics, ledger, state, settings
from .services import dispatch as dispatch_svc
from .ws import events as ws_events


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Ensure server state dirs exist on start; load persisted registry; start worker."""
    enforce_localhost_bind(HOST)
    SERVER_STATE_DIR.mkdir(parents=True, exist_ok=True)
    LOGS_DIR.mkdir(parents=True, exist_ok=True)
    if not TASKS_FILE.exists():
        import json
        TASKS_FILE.write_text(json.dumps({}))
    # Start the serial worker as a background task
    asyncio.create_task(dispatch_svc.worker())
    yield
    # no-op shutdown


app = FastAPI(
    title="Ophar",
    version="0.1.0",
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url=None,
)

# No CORS — local-only server.
app.add_middleware(
    CORSMiddleware,
    allow_origins=[],
    allow_methods=["*"],
    allow_headers=["*"],
)

# Routers
app.include_router(tasks.router, prefix="/api")
app.include_router(metrics.router, prefix="/api")
app.include_router(ledger.router, prefix="/api")
app.include_router(state.router, prefix="/api")
app.include_router(settings.router, prefix="/api")

# WebSocket
app.include_router(ws_events.router)


@app.get("/health")
async def health():
    return {"status": "ok", "host": HOST, "port": PORT}
