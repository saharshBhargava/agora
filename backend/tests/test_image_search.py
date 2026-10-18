"""Automatically choose relevant images while preserving explicit user overrides."""

import json
from uuid import UUID

import pytest

from app.image_identity import ImageIdentity, assess_product, verify_product
from app.image_research import discover, extract_images
from app.item_images import ItemImageService
from tests.test_item_images import Download, Provider, new_item, payload, select


@pytest.mark.parametrize("name", ["Milk", "PS5", "XBOX Series X", "青いマグカップ", "Café kettle"])
async def test_every_nonempty_item_name_is_searched_without_model_or_identity_fields(name):
    provider = Provider()
    await discover(provider, name)
    assert provider.queries[0] == name
    assert 1 <= provider.searches <= 2
    if name == "PS5":
        assert "playstation 5" in provider.queries


async def test_search_router_does_not_require_a_reasoning_model():
    provider = Provider()
    provider.discovery_available = False  # Watches require a reasoning model; image discovery does not.
    provider.router = type("Router", (), {"available": True})()
    await discover(provider, "Milk")
    assert provider.searches == 2


def test_non_latin_identity_does_not_collapse_to_empty_words():
    requested = ImageIdentity(name="青いマグカップ", brand="工房", model="青")
    matching = {"name": "青いマグカップ", "brand": "工房", "model": "青"}
    assert verify_product(requested, matching)
    assert verify_product(requested, {**matching, "name": "赤いマグカップ"}) is None
    assert verify_product(requested, {**matching, "brand": "別工房"}) is None


@pytest.mark.parametrize(
    "name",
    ["PlayStation 5 controller", "PS5 logo", "PS5 branded background", "PS5 Pro replacement cover", "PS4 console"],
)
def test_ambiguous_discovery_still_rejects_unrelated_images(name):
    assert assess_product(ImageIdentity(name="PS5"), {"name": name}, binding="img.alt", official=True) is None


def test_official_console_page_offers_distinct_editions_and_filters_banners():
    html = """<img src="/background-hero.jpg" alt="PS5 console">
    <img src="/disc.jpg" alt="PS5 disc edition console standing vertically">
    <img src="/disc-angle.jpg" alt="PS5 disc edition console standing vertically">
    <img src="/digital.jpg" alt="PS5 digital edition console standing vertically">
    <img src="/controller.jpg" alt="PS5 controller">
    <img src="/ps4.jpg" alt="PS4 console">"""
    choices = extract_images(html, "https://www.playstation.com/en-us/ps5/", "PS5")
    assert [c["image_url"].rsplit("/", 1)[1] for c in choices[:2]] == ["disc.jpg", "digital.jpg"]
    assert all(c["verification"]["status"] == "candidate" for c in choices)


@pytest.mark.parametrize(
    "changes",
    [
        {"name": "Acme Milk 1 l 6 pack"},
        {"name": "Acme Milk 1 l 2 l 1 pack"},
        {"name": "Acme Milk 1 l 1 pack", "brand": "Other"},
    ],
)
def test_candidate_path_does_not_bypass_explicit_conflicts(changes):
    identity = ImageIdentity(name="Acme Milk", brand="Acme", size="1 l", pack_count=1)
    assert assess_product(identity, changes) is None


async def test_best_match_is_automatic_including_cache_and_retroactive_backfill(app, client):
    class MilkProvider(Provider):
        async def fetch(self, url, domains):
            product = {
                "@type": "Product",
                "name": "Farm Milk 1 l",
                "brand": "Farm",
                "size": "1 l",
                "image": "https://images.example.com/milk.jpg",
            }
            return url, '<script type="application/ld+json">' + json.dumps(product) + "</script>"

    provider = MilkProvider()
    service = ItemImageService(app.state.db, provider, Download())
    headers, _, item, path = await new_item(client, "Milk")
    await service.resolve({**await payload(app, item), "refresh": True}, 1)
    result = (await client.get("/" + path, headers=headers)).json()
    assert result["asset"] is not None and result["display_path"] is not None
    assert result["status"] == "ready" and not result["user_selected"]
    assert result["match_status"] == "best_match" and result["unresolved_reason"] is None
    choice = result["choices"][0]
    assert choice["title"] == "Farm Milk 1 l" and choice["verification"]["status"] == "candidate"
    response = await select(client, headers, path, {"mode": "candidate", "asset_id": choice["id"]})
    assert response.status_code == 200, response.text
    assert response.json()["match_status"] == "user_confirmed"
    assert response.json()["asset"]["id"] == choice["id"]
    second_headers, _, second, second_path = await new_item(client, "Milk")
    await service.resolve(await payload(app, second), 1)
    cached = (await client.get("/" + second_path, headers=second_headers)).json()
    assert cached["asset"]["id"] == choice["id"] and not cached["user_selected"]
    assert provider.searches == 2  # Shared cached assets need no second search.
    # Recreate the previous release's unresolved candidate state for an existing item.
    async with app.state.db.system() as conn:
        await conn.execute(
            "UPDATE item_images SET asset_id=NULL,status='fallback' WHERE item_id=$1", UUID(second["id"])
        )
    await service.start()
    await service.start()
    adopted = (await client.get("/" + second_path, headers=second_headers)).json()
    assert adopted["status"] == "ready" and adopted["asset"]["id"] == choice["id"]
    assert adopted["version"] == cached["version"] + 1  # Idempotent startup and stale-worker fence.
    await service.finish("inventory", UUID(second["id"]), cached["version"], [], None)
    assert (await client.get("/" + second_path, headers=second_headers)).json()["asset"] is not None
    assert (await client.get("/" + path, headers=headers)).json()["user_selected"]
    cleared = await select(client, second_headers, second_path, {"mode": "representative"})
    assert cleared.status_code == 200
    await service.start()
    assert (await client.get("/" + second_path, headers=second_headers)).json()["asset"] is None


async def test_console_gets_standard_version_automatically_with_other_versions_available(app, client):
    class ConsoleProvider(Provider):
        async def fetch(self, url, domains):
            return (
                url,
                """<img src="https://images.example.com/pro.jpg" alt="PS5 Pro console">
                <img src="https://images.example.com/digital.jpg" alt="PS5 digital edition console">
                <img src="https://images.example.com/disc.jpg" alt="PS5 disc edition console">
                <img src="https://images.example.com/accessory.jpg" alt="PS5 controller">""",
            )

    headers, _, item, path = await new_item(client, "PS5")
    provider = ConsoleProvider()
    await ItemImageService(app.state.db, provider, Download()).resolve(await payload(app, item), 1)
    result = (await client.get("/" + path, headers=headers)).json()
    assert result["asset"]["title"] == "PS5 disc edition console"
    assert result["status"] == "ready" and result["match_status"] == "best_match"
    assert len(result["choices"]) == 3 and not result["user_selected"]
    digital = next(c for c in result["choices"] if "digital" in c["title"])
    changed = await select(client, headers, path, {"mode": "candidate", "asset_id": digital["id"]})
    assert changed.json()["asset"]["id"] == digital["id"]
    await ItemImageService(app.state.db, provider, Download()).finish(
        "inventory", UUID(item["id"]), result["version"], [UUID(result["asset"]["id"])], None
    )
    assert (await client.get("/" + path, headers=headers)).json()["asset"]["id"] == digital["id"]
