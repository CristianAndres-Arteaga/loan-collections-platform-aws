import logging

import redis
from redis.backoff import NoBackoff
from redis.retry import Retry

from app.core.config import settings

logger = logging.getLogger(__name__)

_client: redis.Redis | None = None


def _get_client() -> redis.Redis | None:
    """Cliente de Valkey, o None si la cache esta deshabilitada (ADR-0011)."""
    global _client
    if settings.cache_host == "disabled":
        return None
    if _client is None:
        _client = redis.Redis(
            host=settings.cache_host,
            port=settings.cache_port,
            ssl=settings.cache_tls,
            socket_connect_timeout=0.3,
            socket_timeout=0.3,
            # redis-py 8 reintenta 10 veces con backoff exponencial por defecto
            # (~2.7 s por operacion con la cache caida). La cache es opcional:
            # si falla, se va directo a PostgreSQL sin reintentar.
            retry=Retry(NoBackoff(), 0),
        )
    return _client


def cache_get(key: str) -> bytes | None:
    client = _get_client()
    if client is None:
        return None
    try:
        return client.get(key)
    except redis.RedisError as exc:
        logger.warning("cache GET fallo para %s: %s", key, exc)
        return None


def cache_set(key: str, value: bytes, ttl_seconds: int) -> None:
    client = _get_client()
    if client is None:
        return
    try:
        client.set(key, value, ex=ttl_seconds)
    except redis.RedisError as exc:
        logger.warning("cache SET fallo para %s: %s", key, exc)


def cache_delete(key: str) -> None:
    client = _get_client()
    if client is None:
        return
    try:
        client.delete(key)
    except redis.RedisError as exc:
        logger.warning("cache DELETE fallo para %s: %s", key, exc)