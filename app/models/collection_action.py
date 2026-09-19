from datetime import datetime
from sqlalchemy import String, Text, BigInteger, DateTime, ForeignKey, func
from sqlalchemy.orm import Mapped, mapped_column
from app.db.base import Base


class CollectionAction(Base):
    __tablename__ = "collection_actions"

    action_id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    loan_id: Mapped[int] = mapped_column(
        ForeignKey("loans.loan_id", ondelete="RESTRICT"), nullable=False
    )
    agent_id: Mapped[int] = mapped_column(
        ForeignKey("users.user_id", ondelete="RESTRICT"), nullable=False
    )
    action_type: Mapped[str] = mapped_column(String(30), nullable=False)
    outcome: Mapped[str | None] = mapped_column(String(100))
    notes: Mapped[str | None] = mapped_column(Text)
    action_date: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, server_default=func.now()
    )