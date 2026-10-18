import json
from uuid import UUID

import pytest

from app.image_identity import ImageIdentity, gtin, verify_product
from app.image_research import extract_images, verify_download
from app.item_images import ItemImageService
from tests.test_item_images import Download, Provider, new_item, page, payload, select


def identity(**changes):
    return ImageIdentity(
        **{
            "name": "Fairlife Whole Milk",
            "brand": "Fairlife",
            "variant": "Whole",
            "size": "52 fl oz",
            "pack_count": 1,
            **changes,
        }
    )


def product(**changes):
    return {
        "@type": "Product",
        "name": "Fairlife Whole Milk 52 fl oz 1 pack",
        "brand": "Fairlife",
        "image": "https://images.example/milk.jpg",
        "size": "52 fl oz",
        "additionalProperty": [{"name": "flavor", "value": "Whole"}, {"name": "pack count", "value": "1"}],
        **changes,
    }


def test_complete_variant_records_evidence_and_equivalent_units():
    result = verify_product(identity(), product())
    assert result["basis"] == "complete_variant" and result["requested"]["pack_count"] == 1
    assert result["observed"]["size"] == "52 fl oz"
    assert verify_product(identity(size="52 fluid ounces"), product())
    assert verify_product(identity(size="1 l"), product(name="Fairlife Whole Milk 1000 ml 1 pack", size="1000 ml"))


@pytest.mark.parametrize(
    "changes",
    [
        {"size": "32 fl oz"},
        {"brand": "Other brand"},
        {"name": "Fairlife Whole Milk 52 fl oz 6 pack"},
        {"name": "Fairlife Whole Milk Chocolate 52 fl oz 1 pack"},
        {"name": "Fairlife Whole Milk 52 oz 1 pack"},
        {"name": "Fairlife Whole Milk 52 fl oz 1 pack lactose free"},
        {"name": "Fairlife Whole Milk bottle sleeve 52 fl oz 1 pack"},
        {"additionalProperty": [{"name": "flavor", "value": "Chocolate"}]},
        {"additionalProperty": [{"name": "pack count", "value": "6"}]},
        {"additionalProperty": [{"name": "flavor", "value": "Whole"}, {"name": "flavor", "value": "Chocolate"}]},
    ],
)
def test_near_matches_cannot_be_automatically_selected(changes):
    assert verify_product(identity(), product(**changes)) is None


@pytest.mark.parametrize("missing", ["brand", "variant", "size", "pack_count"])
def test_missing_identity_never_assumes_a_variant(missing):
    # A generic name contains none of the omitted facts; source-only facts cannot fill the gap.
    requested = identity(name="Milk", **{missing: None})
    assert verify_product(requested, product()) is None


def test_model_generation_color_and_extra_variants_must_match():
    requested = ImageIdentity(name="Sony WH-1000XM5 Headphones Black", brand="Sony", model="WH-1000XM5", color="Black")
    source = {"name": requested.name, "brand": "Sony", "model": "WH-1000XM5", "color": "Black"}
    assert verify_product(requested, source)["basis"] == "brand_model"
    for field, wrong in (("model", "WH-1000XM4"), ("color", "Silver"), ("name", requested.name + " case")):
        assert verify_product(requested, {**source, field: wrong}) is None
    assert (
        verify_product(ImageIdentity(name="Sony WH-1000XM5 Headphones", brand="Sony", model="WH-1000XM5"), source)
        is None
    )


def test_gtin_requires_valid_check_digit_and_exact_source_identifier():
    assert gtin("036000291452") == "00036000291452"
    with pytest.raises(ValueError):
        identity(gtin="036000291453")
    requested = identity(gtin="036000291452")
    assert verify_product(requested, product(gtin12="036000291452"))["basis"] == "gtin"
    assert verify_product(requested, product()) is None
    assert verify_product(requested, product(gtin13="4006381333931")) is None
    assert verify_product(requested, product(gtin12="036000291452", size="32 fl oz")) is None


def test_only_variant_bound_product_images_are_candidates():
    exact = product()
    html = '<meta property="og:image" content="/banner.jpg"><img src="/logo.jpg" alt="Fairlife Whole Milk">'
    html += (
        '<script type="application/ld+json">'
        + json.dumps(
            [
                {**exact, "@type": "ProductGroup", "image": "/group.jpg"},
                product(size="32 fl oz", image="/wrong-size.jpg"),
                exact,
            ]
        )
        + "</script>"
    )
    candidates = extract_images(html, "https://shop.example/milk", identity().query(), identity())
    assert len(candidates) == 1
    assert candidates[0]["image_url"] == exact["image"]
    assert candidates[0]["verification"]["image_binding"] == "Product.image"
    assert extract_images(page(), "https://shop.example/milk", "Milk") == []


@pytest.mark.parametrize(
    "args,accepted",
    [
        ({"result": "consistent", "brand": "Fairlife", "size": "52 fl oz"}, True),
        ({"result": "consistent", "size": "32 fl oz"}, False),
        ({"result": "inconsistent"}, False),
        ({"result": "uncertain"}, False),
        ({"result": "consistent", "invented": "trust me"}, False),
    ],
)
async def test_visual_check_can_veto_but_never_promote_metadata(args, accepted):
    provider = Provider()
    provider.model_available = True

    async def generate(body):
        assert body["contents"][0]["parts"][1]["inlineData"]["mimeType"] == "image/jpeg"
        return {
            "finishReason": "STOP",
            "content": {"role": "model", "parts": [{"functionCall": {"name": "report_image", "args": args}}]},
        }

    provider.generate = generate
    candidate = {"verification": verify_product(identity(), product())}
    assert await verify_download(provider, candidate, b"test fixture") is accepted


async def test_identity_api_resolves_exact_variant_and_persists_evidence(app, client):
    headers, _, item, path = await new_item(client, "Milk")
    body = {"mode": "automatic", "identity": identity().model_dump(exclude_none=True)}
    saved = await select(client, headers, path, body, "exact-identity")
    assert saved.status_code == 200, saved.text
    assert saved.json()["identity"]["size"] == "52 fl oz"
    assert (await select(client, headers, path, body, "exact-identity")).json() == saved.json()
    assert (await select(client, headers, path, body, "repeat-identical-search")).status_code == 429
    provider = Provider()

    async def fetch(url, domains):
        return url, '<script type="application/ld+json">' + json.dumps(product()) + "</script>"

    provider.fetch = fetch
    await ItemImageService(app.state.db, provider, Download()).resolve(await payload(app, item), 1)
    result = (await client.get("/" + path, headers=headers)).json()
    assert result["match_status"] == "exact" and result["asset"]["verification"]["basis"] == "complete_variant"
    assert result["asset"]["verification"]["visual_check"] == "not_performed"
    await client.patch("/v1/inventory/" + item["id"], headers=headers, json={"display_name": "Different item"})
    changed = (await client.get("/" + path, headers=headers)).json()
    assert changed["asset"] is None and changed["identity"] == {"name": "Different item"}


async def test_old_cache_and_legacy_writes_do_not_count_as_verified(app, client):
    headers, household, item, path = await new_item(client)
    async with app.state.db.system() as conn:
        asset = await conn.fetchval(
            """INSERT INTO item_image_assets(data,match_kind) VALUES($1,'product') RETURNING id""",
            await Download().fetch("unused"),
        )
        await conn.execute(
            "UPDATE item_images SET asset_id=$2,candidates=ARRAY[$2::uuid],status='ready' WHERE item_id=$1",
            UUID(item["id"]),
            asset,
        )
    result = (await client.get("/" + path, headers=headers)).json()
    assert result["asset"] is None and result["choices"] == [] and result["match_status"] == "unresolved"
    response = await select(client, headers, path, {"mode": "candidate", "asset_id": str(asset)})
    assert response.status_code == 422
    async with app.state.db.system() as conn:
        await conn.execute("UPDATE item_images SET user_selected=true WHERE item_id=$1", UUID(item["id"]))
    result = (await client.get("/" + path, headers=headers)).json()
    assert result["asset"]["id"] == str(asset) and result["match_status"] == "user_confirmed"


async def test_generic_item_is_searched_without_assigning_an_unrelated_product(app, client):
    headers, _, item, path = await new_item(client, "Milk")
    provider = Provider()
    await ItemImageService(app.state.db, provider, Download()).resolve({**await payload(app, item), "refresh": True}, 1)
    result = (await client.get("/" + path, headers=headers)).json()
    assert result["match_status"] == "unresolved" and result["unresolved_reason"] == "no_verified_match"
    assert result["asset"] is None and result["display_path"] is None and provider.searches == 2


def test_gtin_does_not_override_conflicting_pack_or_title_size():
    requested = identity(gtin="036000291452")
    assert verify_product(requested, product(gtin12=requested.gtin, name="Fairlife Whole Milk 32 fl oz 1 pack")) is None
    assert (
        verify_product(
            requested, product(gtin12=requested.gtin, additionalProperty=[{"name": "pack count", "value": "6"}])
        )
        is None
    )


async def test_visual_bytes_reach_openai_compatible_transport():
    import httpx

    from app.config import Settings
    from app.price_search import PriceSearchProvider

    def respond(request):
        body = json.loads(request.content)
        content = body["messages"][1]["content"]
        assert content[0]["type"] == "text"
        assert content[1]["image_url"]["url"] == "data:image/jpeg;base64,aW1hZ2U="
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "finish_reason": "tool_calls",
                        "message": {
                            "role": "assistant",
                            "tool_calls": [
                                {
                                    "id": "visual",
                                    "type": "function",
                                    "function": {"name": "report_image", "arguments": '{"result":"consistent"}'},
                                }
                            ],
                        },
                    }
                ]
            },
        )

    settings = Settings(_env_file=None, watch_model_provider="openai-compatible", openai_model="vision")
    async with httpx.AsyncClient(transport=httpx.MockTransport(respond)) as http:
        provider = PriceSearchProvider(settings, http)
        candidate = {"verification": verify_product(identity(), product())}
        assert await verify_download(provider, candidate, b"image")
        assert candidate["verification"]["visual_check"] == "consistent"


def test_recognized_full_name_can_supply_attributes_but_source_cannot_invent_them():
    requested = ImageIdentity(name="Fairlife Whole Milk 52 fl oz 1 pack")
    evidence = verify_product(requested, product())
    assert evidence["requested"]["brand"] == "Fairlife"
    assert evidence["requested"]["size"] == "52 fl oz"
    assert evidence["requested"]["pack_count"] == 1
    assert verify_product(ImageIdentity(name="Fairlife Whole Milk"), product()) is None
