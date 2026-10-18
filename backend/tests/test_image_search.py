"""Broad discovery must not silently choose a brand/variant the user never supplied."""

import json

import pytest

from app.image_identity import ImageIdentity, assess_product
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


async def test_candidate_can_be_chosen_and_shared_cache_never_auto_selects_it(app, client):
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
    assert result["asset"] is None and result["display_path"] is None
    assert result["match_status"] == "needs_confirmation" and result["unresolved_reason"] == "choose_variant"
    choice = result["choices"][0]
    assert choice["title"] == "Farm Milk 1 l" and choice["verification"]["status"] == "candidate"
    response = await select(client, headers, path, {"mode": "candidate", "asset_id": choice["id"]})
    assert response.status_code == 200, response.text
    assert response.json()["match_status"] == "user_confirmed"
    assert response.json()["asset"]["id"] == choice["id"]
    second_headers, _, second, second_path = await new_item(client, "Milk")
    await service.resolve(await payload(app, second), 1)
    cached = (await client.get("/" + second_path, headers=second_headers)).json()
    assert cached["asset"] is None and cached["choices"][0]["id"] == choice["id"]
