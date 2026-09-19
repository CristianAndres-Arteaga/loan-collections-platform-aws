from datetime import datetime, timezone

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.models.client import Client
from app.schemas.client import ClientUpdate, ClientRead

router = APIRouter(prefix="/clients", tags=["clients"])


@router.patch("/{client_id}", response_model=ClientRead)
def actualizar_cliente(client_id: int, payload: ClientUpdate, db: Session = Depends(get_db)):
    client = db.get(Client, client_id)
    if client is None:
        raise HTTPException(status_code=404, detail="Cliente no encontrado")

    for campo, valor in payload.model_dump(exclude_unset=True).items():
        setattr(client, campo, valor)

    client.updated_at = datetime.now(timezone.utc)

    db.commit()
    db.refresh(client)
    return client