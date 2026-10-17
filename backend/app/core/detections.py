"""Pure logic for turning per-frame detections into one proposal per product. No I/O, fully unit-tested."""

import re
from dataclasses import dataclass
from statistics import median

from app.vision.base import RawDetection

_WS = re.compile(r"\s+")
_PLURAL = re.compile(r"(?<=[a-z])s\b")


def normalize(name: str) -> str:
    """Key for grouping the same product across frames: lowercase, single spaces, crude singular."""
    return _PLURAL.sub("", _WS.sub(" ", name.lower().strip()))


@dataclass
class MergedDetection:
    label: str
    brand: str | None
    category: str
    count: int
    fill_fraction: float | None
    confidence: float
    box: list[float] | None
    frame_index: int
    frames_seen: int

    @property
    def quantity(self) -> float:
        return quantity(self.count, self.fill_fraction)


def quantity(count: int, fill_fraction: float | None) -> float:
    """Units on hand. One partly used container counts as its fill level: 2 jugs, one half full → 1.5."""
    if count <= 0:
        return 0.0
    if fill_fraction is None:
        return float(count)
    return round(count - 1 + fill_fraction, 3)


def merge_frames(frames: list[list[RawDetection]]) -> list[MergedDetection]:
    """Group detections of the same product across frames.

    Frames from one scan overlap heavily, so counts take the per-frame maximum rather than the sum (summing
    would count the same carton once per frame). Confidence also takes the maximum, fill level the median, and
    the box comes from the most confident sighting.
    """
    groups: dict[tuple[str, str], list[tuple[int, RawDetection]]] = {}
    for index, detections in enumerate(frames):
        for d in detections:
            groups.setdefault((normalize(d.name), (d.brand or "").lower()), []).append((index, d))

    merged: list[MergedDetection] = []
    for sightings in groups.values():
        best_index, best = max(sightings, key=lambda s: s[1].confidence)
        fills = [d.fill_fraction for _, d in sightings if d.fill_fraction is not None]
        merged.append(MergedDetection(
            label=best.name, brand=best.brand, category=best.category,
            count=max(d.count for _, d in sightings),
            fill_fraction=round(median(fills), 3) if fills else None,
            confidence=max(d.confidence for _, d in sightings),
            box=best.box, frame_index=best_index, frames_seen=len({i for i, _ in sightings})))
    merged.sort(key=lambda m: (-m.confidence, m.label))
    return merged


def auto_accept(confidence: float, match_score: float | None, matched_existing: bool,
                min_confidence: float, min_match: float) -> bool:
    """Only sightings of items the household already tracks, seen clearly and matched closely, skip review.
    Anything new or uncertain waits for a person."""
    return matched_existing and match_score is not None and confidence >= min_confidence and match_score >= min_match
