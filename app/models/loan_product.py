from datetime import datetime
from decimal import Decimal
from sqlalchemy import String, Boolean, BigInteger, Integer, Numeric, DateTime, func
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base


class LoanProduct(Base):
    __tablename__ = "loan_products"

    product_id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    product_name: Mapped[str] = mapped_column(String(100), nullable=False)
    interest_rate: Mapped[Decimal] = mapped_column(Numeric(5, 2), nullable=False)
    term_months: Mapped[int] = mapped_column(Integer, nullable=False)
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, server_default="true")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )
