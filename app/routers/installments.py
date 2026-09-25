from datetime import date

from fastapi import APIRouter, Depends, HTTPException, Response, status
from pydantic import TypeAdapter
from sqlalchemy import select, func
from sqlalchemy.orm import Session

from app.core.cache import cache_delete, cache_get, cache_set
from app.core.config import settings
from app.db.session import get_db
from app.models.installment import Installment
from app.models.payment import Payment
from app.schemas.installment import InstallmentRead
from app.schemas.payment import PaymentCreate, PaymentRead

router = APIRouter(prefix="/installments", tags=["installments"])

_installment_list = TypeAdapter(list[InstallmentRead])


def _overdue_cache_key(day: date) -> str:
    # La fecha en la clave evita servir la lista de ayer despues de medianoche (ADR-0011)
    return f"installments:overdue:v1:{day.isoformat()}"


@router.get("/", response_model=list[InstallmentRead])
def listar_cuotas(response: Response, overdue: bool = False, db: Session = Depends(get_db)):
    if not overdue:
        return db.scalars(select(Installment)).all()

    hoy = date.today()  # una sola vez: la misma fecha para la clave y para la consulta
    key = _overdue_cache_key(hoy)

    cached = cache_get(key)
    if cached is not None:
        response.headers["X-Cache"] = "HIT"
        return _installment_list.validate_json(cached)

    stmt = select(Installment).where(
        Installment.due_date < hoy,
        Installment.status.in_(["pending", "partially_paid"]),
    )
    cuotas = _installment_list.validate_python(db.scalars(stmt).all(), from_attributes=True)
    cache_set(key, _installment_list.dump_json(cuotas), settings.cache_ttl_seconds)
    response.headers["X-Cache"] = "MISS"
    return cuotas


@router.post(
    "/{installment_id}/payments",
    response_model=PaymentRead,
    status_code=status.HTTP_201_CREATED,
)
def registrar_pago(installment_id: int, payload: PaymentCreate, db: Session = Depends(get_db)):
    installment = db.get(Installment, installment_id)
    if installment is None:
        raise HTTPException(status_code=404, detail="Cuota no encontrada")

    payment = Payment(installment_id=installment_id, **payload.model_dump())
    db.add(payment)
    db.flush()  # el INSERT ya corrió, pero la transacción sigue abierta

    total_pagado = db.scalar(
        select(func.sum(Payment.amount_paid)).where(Payment.installment_id == installment_id)
    )

    if total_pagado >= installment.amount_due:
        installment.status = "paid"
    else:
        installment.status = "partially_paid"

    db.commit()
    # Despues del commit: si el commit falla, no hay cambio que invalidar (ADR-0011)
    cache_delete(_overdue_cache_key(date.today()))
    db.refresh(payment)
    return payment