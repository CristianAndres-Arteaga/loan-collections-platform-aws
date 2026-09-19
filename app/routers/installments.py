from datetime import date

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import select, func
from sqlalchemy.orm import Session

from app.db.session import get_db
from app.models.installment import Installment
from app.models.payment import Payment
from app.schemas.installment import InstallmentRead
from app.schemas.payment import PaymentCreate, PaymentRead

router = APIRouter(prefix="/installments", tags=["installments"])


@router.get("/", response_model=list[InstallmentRead])
def listar_cuotas(overdue: bool = False, db: Session = Depends(get_db)):
    stmt = select(Installment)
    if overdue:
        stmt = stmt.where(
            Installment.due_date < date.today(),
            Installment.status.in_(["pending", "partially_paid"]),
        )
    return db.scalars(stmt).all()


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
    db.refresh(payment)
    return payment