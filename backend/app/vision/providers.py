import base64
import json
import re
from hashlib import sha256 as hash_bytes
from pathlib import Path

import httpx

from app.config import Settings
from app.media import sha256
from app.vision.base import (
    PROMPT,
    PROMPT_VERSION,
    RESPONSE_SCHEMA,
    RawDetection,
    VisionError,
    VisionProvider,
    parse_items,
)


def _data_uri(frame: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(frame).decode()


def _raise_for_status(response: httpx.Response) -> None:
    # Provider error bodies can echo our input; only the status code is kept.
    if 300 <= response.status_code < 400:
        raise VisionError("provider_redirect", retryable=False)
    if response.status_code in (401, 403):
        raise VisionError("provider_auth", retryable=False)
    if response.status_code == 429:
        raise VisionError("provider_rate_limited")
    if response.status_code >= 500:
        raise VisionError("provider_unavailable")
    if response.status_code >= 400:
        raise VisionError(f"provider_http_{response.status_code}", retryable=False)


def _chat_items(response: httpx.Response, *, require_stop: bool = False) -> list[RawDetection]:
    try:
        choice = response.json()["choices"][0]
        message = choice["message"]
        finish = choice.get("finish_reason")
        if finish != "stop" and (require_stop or finish is not None):
            raise VisionError("incomplete_output")
        if message.get("refusal") or message.get("tool_calls"):
            raise VisionError("malformed_output")
        content = message["content"]
        if isinstance(content, list):
            content = "".join(p["text"] for p in content
                              if isinstance(p, dict) and isinstance(p.get("text"), str))
        if not isinstance(content, str):
            raise VisionError("malformed_output")
        return parse_items(content)
    except (ValueError, KeyError, IndexError, TypeError, AttributeError) as error:
        raise VisionError("malformed_output") from error


class OpenAICompatibleProvider:
    """Vision over a configured Chat Completions endpoint. Never discovers or substitutes a cloud model."""

    name = "openai-compatible"

    def __init__(self, settings: Settings, client: httpx.AsyncClient):
        self.model, self.client = settings.openai_model, client
        self.url = settings.openai_base_url.rstrip("/") + "/chat/completions"
        # Isolate identically named models hosted by different servers without storing private endpoint URLs.
        endpoint_hash = hash_bytes(str(httpx.URL(self.url)).encode()).hexdigest()
        self.cache_version = f"{PROMPT_VERSION}:{endpoint_hash}"
        self.headers = {}
        if settings.openai_api_key and settings.openai_api_key.get_secret_value():
            self.headers["Authorization"] = f"Bearer {settings.openai_api_key.get_secret_value()}"
        self.timeout = settings.vision_timeout_s

    async def detect(self, frame: bytes) -> list[RawDetection]:
        body = {
            "model": self.model,
            "messages": [{"role": "user", "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url", "image_url": {"url": _data_uri(frame)}},
            ]}],
            "temperature": 0,
            "max_tokens": 4096,
            "response_format": {"type": "json_schema", "json_schema": {
                "name": "inventory", "strict": True, "schema": RESPONSE_SCHEMA}},
        }
        try:
            response = await self.client.post(self.url, json=body, headers=self.headers,
                                              timeout=self.timeout, follow_redirects=False)
        except httpx.TimeoutException as error:
            raise VisionError("provider_timeout") from error
        except httpx.HTTPError as error:
            raise VisionError("provider_unreachable") from error
        _raise_for_status(response)
        return _chat_items(response, require_stop=True)


class PerceptronProvider:
    """Perceptron chat completions (OpenAI-style) with a JSON-schema constrained answer."""

    name = "perceptron"

    def __init__(self, settings: Settings, client: httpx.AsyncClient):
        if not settings.perceptron_api_key:
            raise ValueError("AGORA_PERCEPTRON_API_KEY is required for the perceptron provider")
        self.model, self.client = settings.perceptron_model, client
        self.url = settings.perceptron_base_url.rstrip("/") + "/chat/completions"
        self.headers = {"Authorization": f"Bearer {settings.perceptron_api_key.get_secret_value()}"}
        self.timeout = settings.vision_timeout_s
        self.structured = True

    def _body(self, frame: bytes) -> dict:
        body = {
            "model": self.model,
            "messages": [{"role": "user", "content": [
                {"type": "image_url", "image_url": {"url": _data_uri(frame)}},
                {"type": "text", "text": PROMPT},
            ]}],
            "max_completion_tokens": 2048,
            "temperature": 0,
        }
        if self.structured:
            body["response_format"] = {"type": "json_schema",
                                       "json_schema": {"name": "inventory", "strict": True, "schema": RESPONSE_SCHEMA}}
        return body

    async def detect(self, frame: bytes) -> list[RawDetection]:
        try:
            response = await self.client.post(self.url, json=self._body(frame), headers=self.headers,
                                              timeout=self.timeout, follow_redirects=False)
            if response.status_code == 400 and self.structured:
                # Model or tier without schema-constrained output: fall back to prompt-only JSON once.
                self.structured = False
                response = await self.client.post(self.url, json=self._body(frame), headers=self.headers,
                                                  timeout=self.timeout, follow_redirects=False)
        except httpx.TimeoutException as error:
            raise VisionError("provider_timeout") from error
        except httpx.HTTPError as error:
            raise VisionError("provider_unreachable") from error
        _raise_for_status(response)
        return _chat_items(response)


class GeminiProvider:
    name = "gemini"

    def __init__(self, settings: Settings, client: httpx.AsyncClient):
        if not settings.gemini_api_key:
            raise ValueError("AGORA_GEMINI_API_KEY is required for the gemini provider")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", settings.gemini_model):
            raise ValueError("invalid AGORA_GEMINI_MODEL")
        self.model, self.client = settings.gemini_model, client
        self.url = f"https://generativelanguage.googleapis.com/v1beta/models/{self.model}:generateContent"
        self.headers = {"x-goog-api-key": settings.gemini_api_key.get_secret_value()}
        self.timeout = settings.vision_timeout_s

    async def detect(self, frame: bytes) -> list[RawDetection]:
        body = {
            "contents": [{"role": "user", "parts": [
                {"inlineData": {"mimeType": "image/jpeg", "data": base64.b64encode(frame).decode()}},
                {"text": PROMPT},
            ]}],
            "generationConfig": {"responseMimeType": "application/json", "temperature": 0, "maxOutputTokens": 4096},
        }
        try:
            response = await self.client.post(self.url, json=body, headers=self.headers, timeout=self.timeout,
                                              follow_redirects=False)
        except httpx.TimeoutException as error:
            raise VisionError("provider_timeout") from error
        except httpx.HTTPError as error:
            raise VisionError("provider_unreachable") from error
        _raise_for_status(response)
        try:
            candidate = response.json()["candidates"][0]
            text = "".join(p["text"] for p in candidate["content"]["parts"]
                           if isinstance(p, dict) and not p.get("thought") and isinstance(p.get("text"), str))
        except (ValueError, KeyError, IndexError, TypeError, AttributeError) as error:
            raise VisionError("malformed_output") from error
        if candidate.get("finishReason") not in (None, "STOP"):
            raise VisionError("incomplete_output")
        return parse_items(text)


class ReplayProvider:
    """Serves recorded results from ``seed/replay/<sha256>.json``. Never calls the network.

    Record a real scan once (results land in ``vision_cache``), export it with ``python -m app.tools.export_replay``,
    and the demo works offline from then on.
    """

    name = "replay"
    model = "fixtures"

    def __init__(self, directory: Path):
        self.directory = directory

    async def detect(self, frame: bytes) -> list[RawDetection]:
        path = self.directory / f"{sha256(frame)}.json"
        if not path.is_file():
            raise VisionError("no_replay_fixture", retryable=False)
        return parse_items(json.loads(path.read_text(encoding="utf-8")))


def make_provider(kind: str, settings: Settings, client: httpx.AsyncClient) -> VisionProvider | None:
    if kind == "openai-compatible":
        return OpenAICompatibleProvider(settings, client)
    if kind == "perceptron":
        return PerceptronProvider(settings, client)
    if kind == "gemini":
        return GeminiProvider(settings, client)
    if kind == "replay":
        return ReplayProvider(settings.replay_dir)
    return None
