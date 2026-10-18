"""Snapshot round trip: everything the other tests created survives export → import into a fresh database."""

import uuid

import asyncpg

from app.tools.snapshot import export, restore
from tests.conftest import ADMIN_URL, _with_db


async def test_snapshot_round_trip_preserves_rows_and_audit_chain(app, client, tmp_path):
    from tests.conftest import login

    await login(client, "snapshot_user")  # make sure there is data even when this file runs alone
    source = app.state.db.dsn
    archive = tmp_path / "demo.zip"
    manifest = await export(source, str(archive))
    assert {"users", "inventory_observations", "audit_log", "merchants"} <= {t["name"] for t in manifest["tables"]}

    name = f"agora_restore_{uuid.uuid4().hex[:8]}"
    admin = await asyncpg.connect(ADMIN_URL)
    await admin.execute(f'CREATE DATABASE "{name}"')
    target = _with_db(ADMIN_URL, name)
    try:
        counts = await restore(target, str(archive))
        src, dst = await asyncpg.connect(source), await asyncpg.connect(target)
        try:
            for table in ("users", "households", "inventory_items", "inventory_observations", "scans",
                          "scan_detections", "merchants", "audit_log"):
                expected = await src.fetchval(f"SELECT count(*) FROM {table}")
                assert counts[table] == expected == await dst.fetchval(f"SELECT count(*) FROM {table}"), table
            # Hashes were copied verbatim, so the restored chain still verifies, and new rows extend it.
            from app.routers.audit import VERIFY_SQL

            assert (await dst.fetchrow(VERIFY_SQL))["first_broken_id"] is None
            await dst.execute("INSERT INTO audit_log (actor_type, action, prev_hash, hash) "
                              "VALUES ('system', 'x', '', '')")
            assert (await dst.fetchrow(VERIFY_SQL))["first_broken_id"] is None
            # Generated columns were recomputed, and sequences continue after the imported ids.
            assert await dst.fetchval("SELECT count(*) FROM merchants WHERE normalized_name IS NULL") == 0
            # Re-importing over existing data replaces it rather than duplicating.
            again = await restore(target, str(archive))
            assert again["users"] == counts["users"]
        finally:
            await src.close()
            await dst.close()
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()
