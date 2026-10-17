import base64
import json
import re
from pathlib import Path

import httpx

from app.config import Settings
from app.media import sha256
from app.vision.base import PROMPT, RESPONSE_SCHEMA, RawDetection, VisionError, VisionProvider, parse_items


def _data_uri(frame: bytes) -> str:
    return "data:image/jpeg;base64," + base64.b64encode(frame).decode()


def _raise_for_status(response: httpx.Response) -> None:
    # Provider error bodies can echo our input; only the status code is kept.
    if response.status_code in (401, 403):
        raise VisionError("provider_auth", retryable=False)
    if response.status_code == 429:
        raise VisionError("provider_rate_limited")
    if response.status_code >= 500:
        raise VisionError("provider_unavailable")
    if response.status_code >= 400:
        raise VisionError(f"provider_http_{response.status_code}", retryable=False)


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
                                              timeout=self.timeout)
            if response.status_code == 400 and self.structured:
                # Model or tier without schema-constrained output: fall back to prompt-only JSON once.
                self.structured = False
                response = await self.client.post(self.url, json=self._body(frame), headers=self.headers,
                                                  timeout=self.timeout)
        except httpx.TimeoutException as error:
            raise VisionError("provider_timeout") from error
        except httpx.HTTPError as error:
            raise VisionError("provider_unreachable") from error
        _raise_for_status(response)
        try:
            message = response.json()["choices"][0]["message"]["content"]
        except (ValueError, KeyError, IndexError, TypeError) as error:
            raise VisionError("malformed_output") from error
        if isinstance(message, list):  # content parts
            message = "".join(p.get("text", "") for p in message if isinstance(p, dict))
        return parse_items(message)


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
            response = await self.client.post(self.url, json=body, headers=self.headers, timeout=self.timeout)
        except httpx.TimeoutException as error:
            raise VisionError("provider_timeout") from error
        except httpx.HTTPError as error:
            raise VisionError("provider_unreachable") from error
        _raise_for_status(response)
        try:
            candidate = response.json()["candidates"][0]
            text = "".join(p.get("text", "") for p in candidate["content"]["parts"] if not p.get("thought"))
        except (ValueError, KeyError, IndexError, TypeError) as error:
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
    if kind == "perceptron":
        return PerceptronProvider(settings, client)
    if kind == "gemini":
        return GeminiProvider(settings, client)
    if kind == "replay":
        return ReplayProvider(settings.replay_dir)
    return None
