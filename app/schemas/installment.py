from datetime import date, datetime
from decimal import Decimal
from pydantic import BaseModel, ConfigDict


class InstallmentRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    installment_id: int
    loan_id: int
    installment_number: int
    due_date: date
    amount_due: Decimal
    status: str
    created_at: datetime