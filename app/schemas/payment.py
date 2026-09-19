from datetime import datetime
from decimal import Decimal
from pydantic import BaseModel, ConfigDict


class PaymentCreate(BaseModel):
    amount_paid: Decimal
    payment_method: str


class PaymentRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    payment_id: int
    installment_id: int
    amount_paid: Decimal
    payment_date: datetime
    payment_method: str
    created_at: datetime