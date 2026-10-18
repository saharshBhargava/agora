"""API -> durable worker -> grounded discovery -> merchant verification -> APNs transport -> inbox.

Only the external HTTP boundaries are fixtures; real ordinary-account auth, database, queue, matching,
outbox, and delivery code all run together. The designated demo path is tested separately on iOS.
"""
import json
from uuid import uuid4

import asyncpg
import httpx
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec

from app.config import Settings
from app.main import create_app
from app.migrate import migrate
from app.price_search import PriceSearchProvider, ProductFetcher
from tests.conftest import ADMIN_URL, _with_db, login
from tests.test_price_search import CRITERIA, URL, product_page, research_response
from tests.test_watch_model import completion


@pytest.mark.parametrize("search_provider", ["google", "keenable"])
@pytest.mark.parametrize("model_provider", ["gemini", "openai-compatible"])
@pytest.mark.parametrize(('apns_enabled', 'push_requested'), [(True, True), (False, True), (False, False)])
async def test_ordinary_account_complete_discovery_delivery_pipeline(
        monkeypatch, apns_enabled, push_requested, search_provider, model_provider):
    if not ADMIN_URL:
        pytest.skip("set AGORA_TEST_DATABASE_URL")
    name = "agora_pipeline_" + uuid4().hex[:10]
    admin = await asyncpg.connect(ADMIN_URL)
    await admin.execute(f'CREATE DATABASE "{name}"')
    database_url = _with_db(ADMIN_URL, name)
    private_key = ec.generate_private_key(ec.SECP256R1()).private_bytes(
        serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()).decode()
    requests = []
    async def resolve(host):
        assert host == "retailer.example"
        return "93.184.216.34"
    monkeypatch.setattr("app.price_search.resolve_public", resolve)

    def remote(request):
        requests.append(request)
        if request.url.host == "generativelanguage.googleapis.com":
            return research_response(request)
        if request.url.host == 'localhost':
            last = json.loads(request.content)['messages'][-1]
            if last['role'] == 'user':
                reply = completion('web_search', {'query': 'Lodge skillet'})
            elif last['tool_call_id'] == 'call_web_search':
                reply = completion('web_fetch', {'url': URL})
            else:
                reply = completion()
            return httpx.Response(200, json=reply)
        if request.url.host == "api.keenable.ai":
            assert "x-api-key" not in request.headers and "x-goog-api-key" not in request.headers
            return httpx.Response(200, json={"results": [{"url": URL, "title": "Skillet"}]})
        if request.url.host == "api.sandbox.push.apple.com":
            assert apns_enabled and push_requested
            return httpx.Response(200)
        assert request.url.host == "93.184.216.34" and request.headers["host"] == "retailer.example"
        return httpx.Response(200, text=product_page(), headers={"content-type": "text/html"})

    try:
        await migrate(database_url)
        settings = Settings(_env_file=None, watch_search_providers=[search_provider],
                        env="test", database_url=database_url, run_worker_in_process=False,
                            watch_search_api_key=("test-only" if model_provider == 'gemini'
                                                  or search_provider == 'google' else None),
                            watch_model_provider=model_provider, openai_model='local-tools-model',
                            apns_enabled=apns_enabled,
                            apns_key_id="test-key" if apns_enabled else None,
                            apns_team_id="test-team" if apns_enabled else None,
                            apns_private_key=private_key if apns_enabled else None)
        app = create_app(settings)
        async with httpx.AsyncClient(transport=httpx.MockTransport(remote)) as external:
            async with app.router.lifespan_context(app):
                app.state.watches.provider = PriceSearchProvider(settings, external, ProductFetcher(external))
                app.state.notifications.http_client = external
                app.state.notifications._owns_client = False
                async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://test") as api:
                    headers = await login(api, "ordinarybuyer")
                    user = (await api.get("/v1/me", headers=headers)).json()
                    household = user["households"][0]["id"]
                    device = await api.post("/v1/push-devices", headers=headers,
                                            json={"token": "a" * 64, "environment": "sandbox"})
                    assert device.status_code == 200
                    assert device.json()["delivery_status"] == ("available" if apns_enabled else "unavailable")
                    item = await api.post("/v1/wishlist", headers=headers,
                                          json={"title": "Lodge cast iron skillet", "household_id": household})
                    assert item.status_code == 201
                    key = uuid4().hex
                    request = {"confirmed": True, "criteria": CRITERIA,
                               "subscription": {"push_enabled": push_requested}}
                    watch_response = await api.put(f"/v1/wishlist/{item.json()['id']}/watch",
                                                   headers=headers | {"Idempotency-Key": key}, json=request)
                    assert watch_response.status_code == 200, watch_response.text
                    watch_id = watch_response.json()["id"]
                    # The actual worker claims the committed check and then its committed delivery job.
                    assert await app.state.worker.drain() == 1 + int(push_requested)
                    watch = (await api.get(f"/v1/watches/{watch_id}", headers=headers)).json()
                    assert watch["last_result"] == "matched"
                    assert watch["runs"][0]["status"] == "succeeded"
                    assert len(watch["matches"]) == 1 and watch["matches"][0]["is_current"]
                    inbox = (await api.get("/v1/notifications", headers=headers)).json()
                    assert len(inbox) == 1 and inbox[0]["watch_id"] == watch_id
                    sent = [r for r in requests if r.url.host == "api.sandbox.push.apple.com"]
                    assert len(sent) == int(apns_enabled and push_requested)
                    if sent:
                        assert json.loads(sent[0].content)["notification_id"] == inbox[0]["id"]
                        assert sent[0].headers["apns-id"] == inbox[0]["id"]
                        assert "x-goog-api-key" not in sent[0].headers
                    replay = await api.put(f"/v1/wishlist/{item.json()['id']}/watch",
                                           headers=headers | {"Idempotency-Key": key}, json=request)
                    assert replay.status_code == 200
                    assert await app.state.worker.drain() == 0
                    read = await api.post(f"/v1/notifications/{inbox[0]['id']}/read", headers=headers)
                    assert read.status_code == 200 and read.json()["read_at"]
                    # Research and inbox work with no APNs credentials and with push switched off.
                    assert len(requests) == 5 + len(sent)
    finally:
        await admin.execute(f'DROP DATABASE IF EXISTS "{name}" WITH (FORCE)')
        await admin.close()
