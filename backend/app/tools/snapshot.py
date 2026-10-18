"""Copy all app data between databases, e.g. from Tiger Cloud to a laptop if hosting fails:

    uv run python -m app.tools.snapshot export demo.zip --database-url "<tiger url>"
    uv run python -m app.tools.snapshot import demo.zip --database-url "<local url>"

Works between any Postgres versions with or without TimescaleDB, because it copies rows, not storage. Import
runs migrations first, replaces the target's app data in one transaction, keeps audit hashes intact, and
resets ID sequences. The file contains personal demo data: keep it out of git and delete it after use.
"""

import argparse
import asyncio
import csv
import io
import json
import os
import zipfile
from datetime import UTC, datetime

import asyncpg

from app.migrate import migrate

SKIP = {"schema_migrations", "jobs"}  # migration bookkeeping, and transient work that would re-run


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


async def export(dsn: str, path: str) -> dict:
    conn = await asyncpg.connect(dsn)
    try:
        manifest = {"exported_at": datetime.now(UTC).isoformat(), "tables": [],
                    "migrations": [r["name"] for r in await conn.fetch("SELECT name FROM schema_migrations")]}
        with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
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
        return manifest
    finally:
        await conn.close()


async def restore(dsn: str, path: str) -> dict:
    await migrate(dsn)
    conn = await asyncpg.connect(dsn)
    try:
        with zipfile.ZipFile(path) as archive:
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
                for table in tables:
                    data = archive.read(f"{table['name']}.csv")
                    header = next(csv.reader(io.StringIO(data.split(b"\n", 1)[0].decode())), [])
                    if header:
                        await conn.copy_to_table(table["name"], source=io.BytesIO(data), columns=header,
                                                 format="csv", header=True)
                    counts[table["name"]] = await conn.fetchval(f'SELECT count(*) FROM public."{table["name"]}"')
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
    if args.action == "export":
        manifest = asyncio.run(export(args.database_url, args.file))
        print(f"exported {len(manifest['tables'])} tables to {args.file}")
    else:
        counts = asyncio.run(restore(args.database_url, args.file))
        print("imported: " + ", ".join(f"{t}={n}" for t, n in counts.items() if n))


if __name__ == "__main__":
    main()
