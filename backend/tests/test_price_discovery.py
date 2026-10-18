"""Product discovery regressions: articles must not exhaust the merchant-read budget."""
import httpx
import pytest

from app.config import Settings
from app.price_search import PriceSearchProvider
from app.watch_research import product_links
from tests.test_price_search import CRITERIA, product_page


@pytest.mark.parametrize('url,title', [
    ('https://publisher.example/console-price-hike', 'Console price hike'),
    ('https://publisher.example/price.pdf?n=console', 'Console prices'),
    ('https://publisher.example/article', 'How much does a console cost?'),
    ('https://publisher.example/news/console', 'Buy a console'),
    ('https://publisher.example/console-review', 'Console review'),
])
def test_nonmerchant_results_are_not_browser_candidates(url, title):
    assert not PriceSearchProvider.shopping_source({'url': url, 'title': title})


def test_product_links_after_navigation_preserve_identity_and_domains():
    html = '<nav>' + ''.join(f'<a href="/help/{n}">Help</a>' for n in range(80)) + '</nav>'
    html += '''<main>
        <a href="/products/skillet"><img alt="Lodge cast iron skillet 10 inch"></a>
        <a href="/products/wrong">Lodge cast iron skillet 12 inch</a>
        <a href="https://outside.example/products/skillet">Lodge cast iron skillet 10 inch</a>
        <a href="http://localhost/products/skillet">Lodge cast iron skillet 10 inch</a>
        <a href="/products/review">Lodge cast iron skillet 10 inch review</a>
    </main>'''
    assert product_links(html, 'https://shop.example/category/cookware',
                         {**CRITERIA, 'allowed_domains': ['shop.example']}) == [
                             'https://shop.example/products/skillet']


async def test_category_read_discovers_product_and_checks_it_without_another_search(monkeypatch):
    settings = Settings(_env_file=None, gemini_api_key=None, watch_search_api_key=None)
    async with httpx.AsyncClient() as client:
        provider = PriceSearchProvider(settings, client)
        category = 'https://shop.example/category/cookware'
        product = 'https://shop.example/products/skillet'
        reads, searches = [], []

        async def sources(query, criteria, limit, *, budget):
            searches.append(query)
            return [{'url': 'https://news.example/price-hike', 'title': 'Skillet price hike'},
                    {'url': category, 'title': 'Buy Lodge cookware'},
                    {'url': 'https://shop.example/catalog.pdf', 'title': 'Catalog'}]

        async def fetch(url, domains):
            reads.append(url)
            if url == category:
                return url, '<a href="/products/skillet">Lodge cast iron skillet 10 inch</a>'
            return url, product_page(url=url)

        monkeypatch.setattr(provider, 'search_sources', sources)
        monkeypatch.setattr(provider.fetcher, 'fetch', fetch)
        result = await provider.search(CRITERIA, [])
    assert reads == [category, product]
    assert len(searches) == 1
    assert result.browser_urls[0] == product
    assert provider.has_usable_price(CRITERIA, result)


async def test_direct_url_stays_pinned_even_when_page_links_to_another_product(monkeypatch):
    settings = Settings(_env_file=None, gemini_api_key=None, watch_search_api_key=None)
    async with httpx.AsyncClient() as client:
        provider = PriceSearchProvider(settings, client)
        url = 'https://shop.example/products/pinned'
        async def fetch(url, domains):
            return url, '<a href="/products/other">Lodge cast iron skillet 10 inch</a>'
        monkeypatch.setattr(provider.fetcher, 'fetch', fetch)
        result = await provider.search({**CRITERIA, 'product_url': url}, [])
    assert result.browser_urls == [url]
    assert result.checked_urls == [url]
    assert not result.discovered_urls


def test_retailer_diversity_never_promotes_categories_above_product_pages():
    urls = ['https://one.example/products/mug', 'https://two.example/category/mugs',
            'https://one.example/products/red-mug', 'https://three.example/product/blue-mug']
    assert PriceSearchProvider.retailer_urls(urls) == [urls[0], urls[3], urls[2], urls[1]]
    assert not PriceSearchProvider.shopping_source(
        {'url': 'https://shop.example/products/pre-owned-mug'}, {'condition': 'new'})


def test_product_link_attributes_can_be_empty():
    assert product_links('<a href="/products/skillet" aria-label><img alt>Lodge cast iron skillet 10 inch</a>',
                         'https://shop.example', CRITERIA) == ['https://shop.example/products/skillet']
