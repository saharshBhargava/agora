"""Copy all app data between databases, e.g. from Tiger Cloud to a laptop if hosting fails:

    uv run python -m app.tools.snapshot export demo.zip --database-url "<tiger url>"
    uv run python -m app.tools.snapshot import demo.zip --database-url "<local url>"

Works between any Postgres versions with or without TimescaleDB, because it copies rows, not storage. Import
runs migrations first, replaces the target's app data in one transaction, keeps audit hashes intact, and
resets ID sequences. The file contains personal demo data: keep it out of git and delete it after use.

With AGORA_BACKUP_PASSPHRASE set, export writes an encrypted file (AES-256-GCM, scrypt-derived key) and import
decrypts it, so backups can sit somewhere public, like a GitHub Actions artifact, without exposing data.
"""

import argparse
import asyncio
import csv
import io
import json
import os
import secrets
import zipfile
from datetime import UTC, datetime
from pathlib import Path

import asyncpg
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.kdf.scrypt import Scrypt

from app.migrate import migrate

SKIP = {"schema_migrations", "jobs"}  # migration bookkeeping, and transient work that would re-run
MAGIC = b"AGORA-SNAPSHOT-AESGCM-1\n"
PASSPHRASE_ENV = "AGORA_BACKUP_PASSPHRASE"  # noqa: S105 - the variable name, not a secret


def _key(passphrase: str, salt: bytes) -> bytes:
    return Scrypt(salt=salt, length=32, n=2**15, r=8, p=1).derive(passphrase.encode())


def encrypt(data: bytes, passphrase: str) -> bytes:
    salt, nonce = secrets.token_bytes(16), secrets.token_bytes(12)
    return MAGIC + salt + nonce + AESGCM(_key(passphrase, salt)).encrypt(nonce, data, MAGIC)


def decrypt(blob: bytes, passphrase: str | None) -> bytes:
    if not blob.startswith(MAGIC):
        return blob  # a plain, unencrypted snapshot
    if not passphrase:
        raise SystemExit(f"this snapshot is encrypted: set {PASSPHRASE_ENV} to its passphrase")
    body = blob[len(MAGIC):]
    try:
        return AESGCM(_key(passphrase, body[:16])).decrypt(body[16:28], body[28:], MAGIC)
    except Exception as error:  # noqa: BLE001 - wrong passphrase and tampering look the same
        raise SystemExit("could not decrypt the snapshot: wrong passphrase or damaged file") from error


async def _tables(conn: asyncpg.Connection) -> list[str]:
    """App tables in foreign-key order: every table comes after the tables it references."""
    names = [r["relname"] for r in await conn.fetch(
        """SELECT c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') ORDER BY c.relname""") if r["relname"] not in SKIP]
    edges = await conn.fetch(
        """SELECT src.relname AS child, dst.relname AS parent FROM pg_constraint k
           JOIN pg_class src ON src.oid = k.conrelid JOIN pg_class dst ON dst.oid = k.confrelid
           JOIN pg_namespace n ON n.oid = src.relnamespace
           WHERE k.contype = 'f' AND n.nspname = 'public' AND src.relname <> dst.relname""")
    parents = {name: set() for name in names}
    for e in edges:
        if e["child"] in parents and e["parent"] in parents:
            parents[e["child"]].add(e["parent"])
    ordered: list[str] = []
    while parents:
        ready = sorted(t for t, deps in parents.items() if not deps - set(ordered))
        if not ready:
            raise RuntimeError(f"circular foreign keys among {sorted(parents)}")
        for t in ready:
            ordered.append(t)
            del parents[t]
    return ordered


async def _columns(conn: asyncpg.Connection, table: str) -> list[str]:
    """Stored columns only; generated ones are recomputed on import."""
    rows = await conn.fetch(
        """SELECT attname FROM pg_attribute WHERE attrelid = ('public.' || quote_ident($1))::regclass
           AND attnum > 0 AND NOT attisdropped AND attgenerated = '' ORDER BY attnum""", table)
    return [r["attname"] for r in rows]


async def export(dsn: str, path: str, passphrase: str | None = None) -> dict:
    conn = await asyncpg.connect(dsn)
    try:
        manifest = {"exported_at": datetime.now(UTC).isoformat(), "tables": [],
                    "migrations": [r["name"] for r in await conn.fetch("SELECT name FROM schema_migrations")]}
        target = io.BytesIO()
        with zipfile.ZipFile(target, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            async with conn.transaction(isolation="repeatable_read", readonly=True):  # one consistent snapshot
                for table in await _tables(conn):
                    columns = await _columns(conn, table)
                    buffer = io.BytesIO()
                    # COPY (SELECT ...) rather than COPY table: hypertable rows live in chunks, not the parent.
                    select = "SELECT {} FROM public.{}".format(", ".join(f'"{c}"' for c in columns), f'"{table}"')
                    await conn.copy_from_query(select, output=buffer, format="csv", header=True)
                    archive.writestr(f"{table}.csv", buffer.getvalue())
                    rows = max(buffer.getvalue().count(b"\n") - 1, 0)
                    manifest["tables"].append({"name": table, "columns": columns, "approx_rows": rows})
            archive.writestr("manifest.json", json.dumps(manifest, indent=2))
        data = target.getvalue()
        await asyncio.to_thread(Path(path).write_bytes, encrypt(data, passphrase) if passphrase else data)
        return manifest
    finally:
        await conn.close()


async def restore(dsn: str, path: str, passphrase: str | None = None) -> dict:
    await migrate(dsn)
    conn = await asyncpg.connect(dsn)
    try:
        plain = decrypt(await asyncio.to_thread(Path(path).read_bytes), passphrase)
        with zipfile.ZipFile(io.BytesIO(plain)) as archive:
            manifest = json.loads(archive.read("manifest.json"))
            present = set(await _tables(conn))
            tables = [t for t in manifest["tables"] if t["name"] in present]
            missing = [t["name"] for t in manifest["tables"] if t["name"] not in present]
            if missing:
                print(f"skipping tables this database doesn't have (older code?): {missing}")
            counts = {}
            async with conn.transaction():
                names = ", ".join(f'public."{t["name"]}"' for t in tables)
                await conn.execute(f"TRUNCATE {names} RESTART IDENTITY CASCADE")
                # The chain trigger would re-hash imported rows; copy them verbatim instead.
                await conn.execute("ALTER TABLE audit_log DISABLE TRIGGER audit_chain")
                # Image triggers would create duplicate bindings/jobs before those tables are restored.
                image_triggers = (("inventory_items", "inventory_image"), ("wishlist_items", "wishlist_image"),
                                  ("shopping_list_items", "list_image"), ("price_watches", "watch_image_source"))
                for table_name, trigger in image_triggers:
                    await conn.execute(f'ALTER TABLE "{table_name}" DISABLE TRIGGER "{trigger}"')
                for table in tables:
                    data = archive.read(f"{table['name']}.csv")
                    header = next(csv.reader(io.StringIO(data.split(b"\n", 1)[0].decode())), [])
                    if header:
                        await conn.copy_to_table(table["name"], source=io.BytesIO(data), columns=header,
                                                 format="csv", header=True)
                    counts[table["name"]] = await conn.fetchval(f'SELECT count(*) FROM public."{table["name"]}"')
                for table_name, trigger in image_triggers:
                    await conn.execute(f'ALTER TABLE "{table_name}" ENABLE TRIGGER "{trigger}"')
                # Also support snapshots made before image bindings existed. Preserve imported overrides.
                await conn.execute("""INSERT INTO item_images
                    (kind,item_id,household_id,inventory_id,wishlist_id,list_item_id)
                    SELECT 'inventory',id,household_id,id,NULL::uuid,NULL::uuid FROM inventory_items
                    UNION ALL SELECT 'wishlist',id,household_id,NULL,id,NULL FROM wishlist_items
                    UNION ALL SELECT 'list',id,household_id,NULL,NULL,id FROM shopping_list_items
                    ON CONFLICT(kind,item_id) DO NOTHING""")
                await conn.execute("DELETE FROM jobs WHERE kind='image.resolve'")
                await conn.execute("""INSERT INTO jobs(kind,payload,max_attempts)
                    SELECT 'image.resolve',jsonb_build_object('kind',kind,'item_id',item_id,'version',version),2
                    FROM item_images WHERE status='queued' AND NOT user_selected""")
                await conn.execute("ALTER TABLE audit_log ENABLE TRIGGER audit_chain")
                serials = await conn.fetch(
                    """SELECT table_name, column_name FROM information_schema.columns
                       WHERE table_schema = 'public' AND column_default LIKE 'nextval(%'""")
                for row in serials:
                    table, column = f'public."{row["table_name"]}"', row["column_name"]
                    await conn.execute(
                        f'SELECT setval(pg_get_serial_sequence($1, $2), '
                        f'coalesce((SELECT max("{column}") FROM {table}), 0) + 1, false)', table, column)
        return counts
    finally:
        await conn.close()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("action", choices=["export", "import"])
    parser.add_argument("file")
    parser.add_argument("--database-url", default=os.environ.get("AGORA_DATABASE_URL"))
    args = parser.parse_args()
    if not args.database_url:
        parser.error("pass --database-url or set AGORA_DATABASE_URL")
    passphrase = os.environ.get(PASSPHRASE_ENV) or None
    if args.action == "export":
        manifest = asyncio.run(export(args.database_url, args.file, passphrase))
        rows = sum(t["approx_rows"] for t in manifest["tables"])
        print(f"exported {len(manifest['tables'])} tables (~{rows} rows) to {args.file}"
              + (" (encrypted)" if passphrase else ""))
    else:
        counts = asyncio.run(restore(args.database_url, args.file, passphrase))
        print("imported: " + ", ".join(f"{t}={n}" for t, n in counts.items() if n))


if __name__ == "__main__":
    main()
