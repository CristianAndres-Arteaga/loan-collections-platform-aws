from fastapi import FastAPI

from app import models  # fuerza el registro de las 8 tablas en Base.metadata
from app.routers import clients, installments

app = FastAPI(title="Loan Collections API")

app.include_router(clients.router)
app.include_router(installments.router)


@app.get("/health")
def health_check():
    return {"status": "ok"}