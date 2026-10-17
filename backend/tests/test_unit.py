import io
import time

import jwt
import pytest
from PIL import Image

from app.auth import DEV_AUDIENCE, DEV_ISSUER, TokenVerifier, mint_dev_token
from app.config import Settings
from app.core.detections import auto_accept, merge_frames, normalize, quantity
from app.errors import Problem
from app.media import sanitize_image
from app.vision.base import RawDetection, VisionError, parse_items
from tests.conftest import fridge_photo


def det(name, count=1, conf=0.9, fill=None, brand=None):
    return RawDetection(name=name, brand=brand, category="dairy", count=count, fill_fraction=fill, box=None,
                        confidence=conf)


def test_quantity_counts_partial_container_by_fill():
    assert quantity(2, 0.5) == 1.5
    assert quantity(3, None) == 3.0
    assert quantity(0, 0.7) == 0.0


def test_merge_takes_max_count_across_overlapping_frames():
    merged = merge_frames([[det("eggs", 6, 0.7)], [det("egg", 9, 0.95), det("milk", 1, fill=0.4)],
                           [det("milk", 1, 0.8, fill=0.6)]])
    by_label = {normalize(m.label): m for m in merged}
    assert by_label["egg"].count == 9 and by_label["egg"].confidence == 0.95 and by_label["egg"].frames_seen == 2
    assert by_label["milk"].fill_fraction == 0.5 and by_label["milk"].quantity == 0.5


def test_merge_keeps_different_brands_apart():
    merged = merge_frames([[det("yogurt", brand="Fage"), det("yogurt", brand="Chobani")]])
    assert len(merged) == 2


def test_auto_accept_requires_existing_item_and_high_scores():
    assert auto_accept(0.9, 0.9, True, 0.85, 0.8)
    assert not auto_accept(0.9, 0.9, False, 0.85, 0.8)  # new items always get a human look
    assert not auto_accept(0.8, 0.9, True, 0.85, 0.8)
    assert not auto_accept(0.9, None, True, 0.85, 0.8)


def test_parse_items_clamps_and_drops_junk():
    items = parse_items("""```json
    {"items": [
      {"name": "Milk <script>", "brand": null, "category": "dairy", "count": 250, "fill_fraction": 1.7,
       "box": [900, 10, 100, 2000], "confidence": 3},
      {"name": "", "count": 1, "confidence": 0.5},
      {"name": "eggs", "count": "lots", "confidence": 0.5},
      {"name": "beans", "category": "weapons", "count": 2, "confidence": 0.6, "box": [1, 2]},
      "not an object"
    ]}
    ```""")
    assert [i.name for i in items] == ["milk script", "beans"]
    milk, beans = items
    assert milk.count == 100 and milk.fill_fraction == 1.0 and milk.confidence == 1.0
    assert milk.box == [100, 10, 900, 1000]
    assert beans.category == "other" and beans.box is None


def test_parse_items_rejects_non_json():
    with pytest.raises(VisionError):
        parse_items("I see some milk and eggs")


def test_sanitize_strips_exif_and_bounds_size():
    original = fridge_photo()
    assert b"SecretPhoneMaker" in original
    clean = sanitize_image(original, max_side=320)
    assert b"SecretPhoneMaker" not in clean
    with Image.open(io.BytesIO(clean)) as img:
        assert img.format == "JPEG" and max(img.size) == 320 and not img.getexif()


def test_sanitize_rejects_non_images():
    with pytest.raises(Problem) as error:
        sanitize_image(b"%PDF-1.7 not an image", 1600)
    assert error.value.status == 415


def test_dev_tokens_verify_and_reject_tampering():
    settings = Settings(env="test")
    verifier = TokenVerifier(settings)
    token, _ = mint_dev_token(settings, "dev:kedar")
    assert verifier.verify(token) == "dev:kedar"

    forged = jwt.encode({"sub": "dev:kedar", "iss": DEV_ISSUER, "aud": DEV_AUDIENCE, "exp": time.time() + 60},
                        "x" * 40, algorithm="HS256")
    unsigned = jwt.encode({"sub": "dev:kedar", "iss": DEV_ISSUER, "aud": DEV_AUDIENCE, "exp": time.time() + 60},
                          None, algorithm="none")
    expired = jwt.encode({"sub": "dev:kedar", "iss": DEV_ISSUER, "aud": DEV_AUDIENCE, "exp": time.time() - 5},
                         settings.dev_jwt_secret.get_secret_value(), algorithm="HS256")
    for bad in (forged, unsigned, expired, "garbage"):
        with pytest.raises(Problem) as error:
            verifier.verify(bad)
        assert error.value.status == 401


def test_config_refuses_unsafe_deploys():
    with pytest.raises(ValueError, match="not allowed"):
        Settings(env="prod", auth_mode="dev")
    with pytest.raises(ValueError, match="unique"):
        Settings(env="demo", auth_mode="dev")
    Settings(env="demo", auth_mode="dev", dev_jwt_secret="a-real-random-secret-for-the-demo-0123456789")
