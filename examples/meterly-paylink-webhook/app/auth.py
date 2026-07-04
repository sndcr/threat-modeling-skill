from fastapi import Depends, Header, HTTPException
from sqlalchemy import select
from sqlalchemy.orm import Session

from .database import get_db
from .models import Tenant


def get_current_tenant(
    x_api_key: str | None = Header(default=None),
    db: Session = Depends(get_db),
) -> Tenant:
    if not x_api_key:
        raise HTTPException(401, "missing API key")
    tenant = db.scalar(select(Tenant).where(Tenant.api_key == x_api_key))
    if tenant is None:
        raise HTTPException(401, "invalid API key")
    return tenant
