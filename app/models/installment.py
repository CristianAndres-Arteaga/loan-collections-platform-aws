from datetime import date, datetime
from decimal import Decimal
from sqlalchemy import String, BigInteger, Integer, Numeric, Date, DateTime, ForeignKey, Index, func
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base


class Installment(Base):
    __tablename__ = "installments"
    __table_args__ = (
        Index("idx_installments_due_status", "due_date", "status"),
    )

    installment_id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    loan_id: Mapped[int] = mapped_column(
        ForeignKey("loans.loan_id", ondelete="RESTRICT"), nullable=False
    )
    installment_number: Mapped[int] = mapped_column(Integer, nullable=False)
    due_date: Mapped[date] = mapped_column(Date, nullable=False)
    amount_due: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, server_default="pending")
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )