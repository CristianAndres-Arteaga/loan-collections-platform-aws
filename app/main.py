import logging

from fastapi import FastAPI

from app import models  # fuerza el registro de las 8 tablas en Base.metadata
from app.core.config import settings
from app.core.logging_config import setup_logging
from app.routers import clients, installments

setup_logging()
logger = logging.getLogger(__name__)

app = FastAPI(title="Loan Collections API")

app.include_router(clients.router, prefix="/api")
app.include_router(installments.router, prefix="/api")

logger.info(
    "app iniciada: cache=%s, business_timezone=%s",
    "disabled" if settings.cache_host == "disabled" else "enabled",
    settings.business_timezone,
)


@app.get("/health")
def health_check():
    return {"status": "ok"}