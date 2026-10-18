"""/readyz is what Render and the deploy pipeline trust, so it must report the release and fail closed."""

from app import main as main_module


async def test_readyz_reports_release_and_migrations(app, client, monkeypatch):
    monkeypatch.setattr(main_module, "RELEASE_COMMIT", "0123456789abcdef")
    body = (await client.get("/readyz")).json()
    assert body["ok"] is True and body["commit"] == "0123456789abcdef"
    assert body["migrations"]["pending"] == [] and body["migrations"]["latest"].endswith(".sql")
    assert body["migrations"]["expected"] >= 10  # TimescaleDB-only files are excluded on plain Postgres


async def test_readyz_fails_while_migrations_are_missing(app, client):
    healthy = app.state.migrations
    app.state.migrations = {**healthy, "pending": ["9999_not_applied.sql"]}
    try:
        response = await client.get("/readyz")
        assert response.status_code == 503 and response.json()["ok"] is False
    finally:
        app.state.migrations = healthy


async def test_older_release_on_newer_schema_is_healthy(app):
    """After a rollback the database has migrations the older build doesn't know about. That's fine."""
    from app.migrate import migration_status

    async with app.state.db.raw() as conn:
        await conn.execute("INSERT INTO schema_migrations (name, checksum) VALUES ('9999_future.sql', 'x') "
                           "ON CONFLICT DO NOTHING")
        try:
            status = await migration_status(conn, app.state.db.timescale)
            assert status["pending"] == []
        finally:
            await conn.execute("DELETE FROM schema_migrations WHERE name = '9999_future.sql'")
