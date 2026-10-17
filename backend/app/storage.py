import asyncio
import re
from pathlib import Path
from typing import Protocol

from app.config import Settings

_KEY = re.compile(r"^[a-z0-9][a-z0-9/_.-]{0,200}$")


def _check_key(key: str) -> str:
    if not _KEY.match(key) or ".." in key:
        raise ValueError("invalid storage key")
    return key


class Storage(Protocol):
    async def put(self, key: str, data: bytes, content_type: str) -> None: ...
    async def get(self, key: str) -> bytes: ...
    async def delete(self, key: str) -> None: ...


class LocalStorage:
    def __init__(self, root: Path):
        self.root = root.resolve()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        path = (self.root / _check_key(key)).resolve()
        if self.root not in path.parents:
            raise ValueError("invalid storage key")
        return path

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        path = self._path(key)
        await asyncio.to_thread(path.parent.mkdir, parents=True, exist_ok=True)
        await asyncio.to_thread(path.write_bytes, data)

    async def get(self, key: str) -> bytes:
        return await asyncio.to_thread(self._path(key).read_bytes)

    async def delete(self, key: str) -> None:
        await asyncio.to_thread(self._path(key).unlink, missing_ok=True)


class S3Storage:
    """Any S3-compatible private bucket (Cloudflare R2 in the demo deploy)."""

    def __init__(self, settings: Settings):
        import boto3

        self.bucket = settings.s3_bucket
        self.client = boto3.client(
            "s3", endpoint_url=settings.s3_endpoint_url, region_name="auto",
            aws_access_key_id=settings.s3_access_key_id.get_secret_value() if settings.s3_access_key_id else None,
            aws_secret_access_key=(
                settings.s3_secret_access_key.get_secret_value() if settings.s3_secret_access_key else None),
        )

    async def put(self, key: str, data: bytes, content_type: str) -> None:
        await asyncio.to_thread(self.client.put_object, Bucket=self.bucket, Key=_check_key(key), Body=data,
                                ContentType=content_type)

    async def get(self, key: str) -> bytes:
        response = await asyncio.to_thread(self.client.get_object, Bucket=self.bucket, Key=_check_key(key))
        return await asyncio.to_thread(response["Body"].read)

    async def delete(self, key: str) -> None:
        await asyncio.to_thread(self.client.delete_object, Bucket=self.bucket, Key=_check_key(key))


def make_storage(settings: Settings) -> Storage:
    return S3Storage(settings) if settings.storage_backend == "s3" else LocalStorage(settings.storage_dir)
