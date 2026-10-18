"""Provider wire contracts and the complete upload/review/cache path, without paid model calls."""

import json
from uuid import UUID

import httpx
import pytest

from app.config import Settings
from app.main import build_pipeline
from app.vision.base import VisionError, parse_items
from app.vision.providers import GeminiProvider, OpenAICompatibleProvider, PerceptronProvider
from app.vision.service import VisionService
from tests.conftest import MILK, fridge_photo, login
from tests.test_api import upload


def local_settings(**overrides):
    return Settings(env="test", vision_provider="openai-compatible", openai_model="org/vision-model:Q4_K_M",
                    **overrides)


def completion(content=None, finish="stop"):
    return {"choices": [{"finish_reason": finish, "message": {
        "role": "assistant", "content": content if content is not None else json.dumps({"items": [MILK]})}}]}


@pytest.mark.parametrize("key", [None, "local-server-secret"])
async def test_local_image_schema_request_and_optional_auth(key):
    requests = []

    def respond(request):
        requests.append(request)
        return httpx.Response(200, json=completion())

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        provider = OpenAICompatibleProvider(local_settings(openai_api_key=key), client)
        detected = await provider.detect(b"jpeg-bytes")
    request = requests[0]
    assert str(request.url) == "http://localhost:1234/v1/chat/completions"
    assert request.headers.get("authorization") == (f"Bearer {key}" if key else None)
    body = json.loads(request.content)
    assert body["model"] == "org/vision-model:Q4_K_M"
    assert body["response_format"]["json_schema"]["strict"] is True
    assert body["response_format"]["json_schema"]["schema"]["required"] == ["items"]
    assert body["messages"][0]["content"][1]["image_url"]["url"].startswith("data:image/jpeg;base64,")
    assert detected[0].name == "2% milk"


@pytest.mark.parametrize(("status", "code", "retryable"), [
    (302, "provider_redirect", False), (401, "provider_auth", False), (403, "provider_auth", False),
    (400, "provider_http_400", False), (404, "provider_http_404", False),
    (429, "provider_rate_limited", True), (503, "provider_unavailable", True),
])
async def test_local_failures_are_sanitized_and_never_redirect_or_downgrade(status, code, retryable):
    calls = []

    def respond(request):
        calls.append(request)
        return httpx.Response(status, text="private image and API key", headers={"Location": "https://cloud.invalid"})

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond), follow_redirects=True) as client:
        service = build_pipeline(local_settings(), None, client).vision
        assert service.fallback is None
        with pytest.raises(VisionError) as error:
            await service.detect([b"image"], [None])
        assert (error.value.code, error.value.retryable) == (code, retryable)
        assert str(error.value) == code and len(calls) == 1


@pytest.mark.parametrize(("exception", "code"), [
    (httpx.ReadTimeout("private URL"), "provider_timeout"),
    (httpx.ConnectError("private endpoint"), "provider_unreachable"),
])
async def test_local_network_errors(exception, code):
    def respond(request):
        raise exception

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        with pytest.raises(VisionError, match=code):
            await OpenAICompatibleProvider(local_settings(), client).detect(b"image")


@pytest.mark.parametrize("response", [
    {}, {"choices": []}, {"choices": [None]}, {"choices": [{"message": []}]},
    completion("not JSON"), completion('{"items": []}', finish="length"),
    completion([{"text": []}]), completion('{"items": {}}'),
])
async def test_malformed_local_responses_fail_cleanly(response):
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json=response))) as client:
        with pytest.raises(VisionError):
            await OpenAICompatibleProvider(local_settings(), client).detect(b"image")


async def test_local_text_parts_and_explicit_fallback():
    calls = []

    def respond(request):
        calls.append(request.url.host)
        if request.url.host == "localhost":
            return httpx.Response(503)
        return httpx.Response(200, json={"candidates": [{"finishReason": "STOP", "content": {
            "parts": [{"text": json.dumps({"items": [MILK]})}]}}]})

    settings = local_settings(vision_fallback="gemini", gemini_api_key="cloud-key")
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        service = build_pipeline(settings, None, client).vision
        run = await service.detect([b"image"], [None])
        assert run.provider == "gemini" and calls == ["localhost", "generativelanguage.googleapis.com"]
        parts = [{"type": "text", "text": json.dumps({"items": [MILK]})}, {"text": 2}]
        local = OpenAICompatibleProvider(local_settings(), httpx.AsyncClient(
            transport=httpx.MockTransport(lambda _: httpx.Response(200, json=completion(parts)))))
        try:
            assert (await local.detect(b"image"))[0].count == 2
        finally:
            await local.client.aclose()


@pytest.mark.parametrize("url", ["file:///tmp/model", "http://user:secret@localhost/v1", "http://localhost/v1?q=key",
                                 "http://localhost/v1#fragment", "http://",
                                 "http://localhost:bad", "http://local host"])
def test_local_rejects_unsafe_endpoint(url):
    with pytest.raises(ValueError, match="AGORA_OPENAI_BASE_URL"):
        local_settings(openai_base_url=url)


def test_local_requires_model_and_cache_identity_is_endpoint_specific():
    with pytest.raises(ValueError, match="AGORA_OPENAI_MODEL"):
        Settings(env="test", vision_provider="openai-compatible")
    a = OpenAICompatibleProvider(local_settings(), None)
    b = OpenAICompatibleProvider(local_settings(openai_base_url="http://localhost:1235/v1"), None)
    assert a.cache_version != b.cache_version and "localhost" not in a.cache_version


def test_untrusted_categories_and_nonfinite_counts_do_not_crash():
    assert parse_items({"items": [{**MILK, "category": []}]})[0].category == "other"
    for value in (float("nan"), float("inf"), 10 ** 1000):
        assert parse_items({"items": [{**MILK, "count": value}]}) == []


async def test_existing_gemini_and_perceptron_wire_formats():
    calls = []

    def respond(request):
        calls.append(request)
        if "googleapis" in request.url.host:
            return httpx.Response(200, json={"candidates": [{"content": {
                "parts": [{"text": json.dumps({"items": [MILK]})}]}, "finishReason": "STOP"}]})
        if len([r for r in calls if "perceptron" in r.url.host]) == 1:
            return httpx.Response(400)
        return httpx.Response(200, json=completion())

    settings = Settings(env="test", gemini_api_key="gemini-key", perceptron_api_key="perceptron-key")
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as client:
        assert (await GeminiProvider(settings, client).detect(b"image"))[0].name == "2% milk"
        assert (await PerceptronProvider(settings, client).detect(b"image"))[0].name == "2% milk"
    assert calls[0].headers["x-goog-api-key"] == "gemini-key"
    assert "response_format" in json.loads(calls[1].content)
    assert "response_format" not in json.loads(calls[2].content)


async def test_local_upload_review_cache_provenance_and_endpoint_isolation(app, client, monkeypatch):
    headers = await login(client, "local_model_scan")
    photo = fridge_photo(38)
    calls = []

    def respond(request):
        calls.append(str(request.url))
        return httpx.Response(200, json=completion())

    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as model_client:
        service = VisionService(OpenAICompatibleProvider(local_settings(), model_client))
        monkeypatch.setattr(app.state.pipeline, "vision", service)
        scan = (await upload(client, headers, photo)).json()
        await app.state.worker.drain()
        scan = (await client.get(f"/v1/scans/{scan['id']}", headers=headers)).json()
        assert scan["status"] == "needs_review" and scan["provider"] == "openai-compatible"
        assert scan["model"] == "org/vision-model:Q4_K_M"
        reviewed = await client.post(f"/v1/scans/{scan['id']}/review", headers=headers, json={
            "decisions": [{"detection_id": scan["detections"][0]["id"], "action": "accept"}]})
        assert reviewed.status_code == 200
        assert len((await client.get("/v1/inventory", headers=headers)).json()) == 1
        cached = (await upload(client, headers, photo)).json()
        await app.state.worker.drain()
        cached = (await client.get(f"/v1/scans/{cached['id']}", headers=headers)).json()
        assert len(calls) == 1 and cached["provider"] == scan["provider"] and cached["model"] == scan["model"]
        monkeypatch.setattr(app.state.pipeline, "vision", VisionService(OpenAICompatibleProvider(
            local_settings(openai_base_url="http://localhost:1235/v1"), model_client)))
        await upload(client, headers, photo)
        await app.state.worker.drain()
        assert len(calls) == 2 and "1235" in calls[-1]
        # The cache remains household-scoped even for the same configured server and frame.
        outsider = await login(client, "local_model_other_household")
        await upload(client, outsider, photo)
        await app.state.worker.drain()
        assert len(calls) == 3
    me = (await client.get("/v1/me", headers=headers)).json()
    async with app.state.db.scoped(UUID(me["id"])) as conn:
        rows = await conn.fetch("SELECT provider, model, prompt_version FROM vision_cache WHERE household_id = $1",
                                UUID(me["households"][0]["id"]))
        assert len(rows) == 2 and all(r["provider"] == "openai-compatible" for r in rows)
        assert len({r["prompt_version"] for r in rows}) == 2


@pytest.mark.parametrize("missing", [True, False])
async def test_local_requires_explicit_completed_stop_reason(missing):
    payload = completion(finish=None)
    if missing:
        payload["choices"][0].pop("finish_reason")
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json=payload))) as client:
        with pytest.raises(VisionError, match="incomplete_output"):
            await OpenAICompatibleProvider(local_settings(), client).detect(b"image")


async def test_perceptron_preserves_legacy_missing_finish_reason():
    payload = completion()
    payload["choices"][0].pop("finish_reason")
    async with httpx.AsyncClient(transport=httpx.MockTransport(lambda _: httpx.Response(200, json=payload))) as client:
        provider = PerceptronProvider(Settings(env="test", perceptron_api_key="legacy-key"), client)
        assert (await provider.detect(b"image"))[0].name == "2% milk"
