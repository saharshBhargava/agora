"""Vision provider contract, shared prompt and output validation.

Model output is untrusted: it is parsed against a fixed shape, clamped to sane ranges, and never treated as
instructions. Anything that doesn't validate is dropped rather than guessed at.
"""

import json
import math
import re
from dataclasses import asdict, dataclass
from typing import Any, Protocol

PROMPT_VERSION = "inventory-v1"

PROMPT = """You are cataloguing household inventory from a photo of a fridge, freezer, pantry or shelf.
List every distinct grocery or household product you can see. For each product give:
- name: short generic product name, e.g. "2% milk", "large eggs", "cheddar cheese"
- brand: brand if legible, else null
- category: one of produce, dairy, meat, seafood, bakery, frozen, pantry, beverages, snacks, condiments,
  household, personal_care, other
- count: how many separate containers or units of that product are visible (integer)
- fill_fraction: for one partly-used container (milk jug, juice, cereal box), how full it looks from 0 to 1;
  null if not applicable or not visible
- box: [x1, y1, x2, y2] around the best example, on a 0-1000 grid with the origin at the top left
- confidence: 0 to 1, how sure you are about name and count
Ignore people, pets, text on papers and anything that is not a product. Do not guess hidden items.
Answer with JSON only: {"items": [...]}"""

CATEGORIES = {"produce", "dairy", "meat", "seafood", "bakery", "frozen", "pantry", "beverages", "snacks",
              "condiments", "household", "personal_care", "other"}

RESPONSE_SCHEMA: dict[str, Any] = {
    "type": "object",
    "properties": {
        "items": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "name": {"type": "string"},
                    "brand": {"type": ["string", "null"]},
                    "category": {"type": "string", "enum": sorted(CATEGORIES)},
                    "count": {"type": "integer"},
                    "fill_fraction": {"type": ["number", "null"]},
                    "box": {"type": "array", "items": {"type": "number"}},
                    "confidence": {"type": "number"},
                },
                "required": ["name", "brand", "category", "count", "fill_fraction", "box", "confidence"],
                "additionalProperties": False,
            },
        }
    },
    "required": ["items"],
    "additionalProperties": False,
}


class VisionError(Exception):
    def __init__(self, code: str, retryable: bool = True):
        super().__init__(code)
        self.code, self.retryable = code, retryable


@dataclass
class RawDetection:
    name: str
    brand: str | None
    category: str
    count: int
    fill_fraction: float | None
    box: list[float] | None
    confidence: float

    def to_json(self) -> dict[str, Any]:
        return asdict(self)


class VisionProvider(Protocol):
    name: str
    model: str

    async def detect(self, frame: bytes) -> list[RawDetection]: ...


_CLEAN = re.compile(r"[^\w\s%&'.,/-]", re.UNICODE)


def _text(value: Any, limit: int) -> str | None:
    if not isinstance(value, str):
        return None
    cleaned = " ".join(_CLEAN.sub("", value).split())[:limit]
    return cleaned or None


def _num(value: Any, lo: float, hi: float) -> float | None:
    if isinstance(value, bool) or not isinstance(value, int | float):
        return None
    try:
        number = float(value)
    except OverflowError:
        return None
    if not math.isfinite(number):
        return None
    return min(max(number, lo), hi)


def parse_items(payload: Any) -> list[RawDetection]:
    """Validate a provider's {"items": [...]} answer. Accepts a dict or a JSON string, possibly fenced."""
    if isinstance(payload, str):
        payload = _loads_lenient(payload)
    items = payload.get("items") if isinstance(payload, dict) else None
    if not isinstance(items, list):
        raise VisionError("malformed_output")
    out: list[RawDetection] = []
    for item in items[:60]:
        if not isinstance(item, dict):
            continue
        name = _text(item.get("name"), 80)
        count = _num(item.get("count"), 0, 100)
        confidence = _num(item.get("confidence"), 0, 1)
        if not name or count is None or confidence is None:
            continue
        category = item.get("category")
        category = category if isinstance(category, str) and category in CATEGORIES else "other"
        box = item.get("box")
        if not (isinstance(box, list) and len(box) == 4 and all(_num(v, 0, 1000) is not None for v in box)):
            box = None
        else:
            x1, y1, x2, y2 = (_num(v, 0, 1000) for v in box)
            box = [min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)]
        out.append(RawDetection(
            name=name.lower(), brand=_text(item.get("brand"), 60), category=category, count=int(round(count)),
            fill_fraction=_num(item.get("fill_fraction"), 0, 1), box=box, confidence=round(confidence, 3)))
    return out


def _loads_lenient(text: str) -> Any:
    text = text.strip()
    if text.startswith("```"):
        text = text.strip("`")
        text = text.split("\n", 1)[1] if "\n" in text else text
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        start, end = text.find("{"), text.rfind("}")
        if start != -1 and end > start:
            try:
                return json.loads(text[start:end + 1])
            except json.JSONDecodeError:
                pass
    raise VisionError("malformed_output")
