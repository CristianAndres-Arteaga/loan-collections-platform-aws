from datetime import datetime
from pydantic import BaseModel, ConfigDict


class ClientUpdate(BaseModel):
    first_name: str | None = None
    last_name: str | None = None
    document_type: str | None = None
    email: str | None = None
    phone: str | None = None
    address: str | None = None
    is_active: bool | None = None


class ClientRead(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    client_id: int
    first_name: str
    last_name: str
    document_type: str
    document_number: str
    email: str | None
    phone: str | None
    address: str | None
    is_active: bool
    created_at: datetime
    updated_at: datetime