"""Conservative product identity checks. Unknown attributes never become model guesses."""

import re
import unicodedata
from decimal import Decimal

from pydantic import Field, field_validator

from app.schemas import Strict

VERIFICATION_VERSION = 2


def normalized(value):
    return " ".join(re.findall(r"[a-z0-9]+", unicodedata.normalize("NFKD", str(value)).casefold()))


def gtin(value):
    value = re.sub(r"[ -]", "", str(value))
    if not value.isascii() or not value.isdigit() or len(value) not in (8, 12, 13, 14):
        return None
    total = sum(int(n) * (3 if i % 2 == 0 else 1) for i, n in enumerate(reversed(value[:-1])))
    return value.zfill(14) if (10 - total % 10) % 10 == int(value[-1]) else None


class ImageIdentity(Strict):
    name: str = Field(min_length=1, max_length=200)
    brand: str | None = Field(default=None, max_length=100)
    model: str | None = Field(default=None, max_length=100)
    variant: str | None = Field(default=None, max_length=100)
    size: str | None = Field(default=None, max_length=80)
    color: str | None = Field(default=None, max_length=60)
    pack_count: int | None = Field(default=None, ge=1, le=1000, strict=True)
    gtin: str | None = Field(default=None, max_length=20)

    @field_validator("name", "brand", "model", "variant", "size", "color", mode="before")
    @classmethod
    def trim(cls, value):
        return value.strip() if isinstance(value, str) else value

    @field_validator("gtin")
    @classmethod
    def valid_gtin(cls, value):
        if value is not None and not gtin(value):
            raise ValueError("Enter a valid UPC/EAN/GTIN including its check digit")
        return gtin(value) if value else None

    def missing(self):
        if self.gtin:
            return []
        if self.brand and self.model:
            return []
        return [k for k in ("brand", "variant", "size", "pack_count") if not getattr(self, k)]

    def query(self):
        parts = [self.name, self.brand, self.model, self.variant, self.size, self.color, self.gtin]
        if self.pack_count:
            parts.append(f"{self.pack_count} pack")
        return " ".join(dict.fromkeys(p for p in parts if p))[:500]


# Equivalent unit spellings and quantities compare canonically, preserving dimensions.
UNITS = {
    "fl oz": ("volume", Decimal("29.5735295625")),
    "ml": ("volume", Decimal(1)),
    "l": ("volume", Decimal(1000)),
    "oz": ("mass", Decimal("28.349523125")),
    "lb": ("mass", Decimal("453.59237")),
    "g": ("mass", Decimal(1)),
    "kg": ("mass", Decimal(1000)),
    "in": ("length", Decimal("25.4")),
    "cm": ("length", Decimal(10)),
    "mm": ("length", Decimal(1)),
}


def canonical(text):
    text = str(text).casefold()
    for pattern, replacement in (
        (r"\bfluid\s+ounces?\b|\bfl\.?\s*oz\.?", "fl oz"),
        (r"\bounces?\b", "oz"),
        (r"\bpounds?\b|\blbs\b", "lb"),
        (r"\bmillilit(?:er|re)s?\b", "ml"),
        (r"\blit(?:er|re)s?\b", "l"),
        (r"\binches\b|\binch\b", "in"),
        (r"\bpack\s+of\s+(\d+)\b", r"\1 pack"),
        (r"\b(\d+)\s*[- ]?(?:pk|packs?|count|ct)\b", r"\1 pack"),
        (r"\bsingle\s+(?:bottle|carton|pack|unit)\b", "1 pack"),
    ):
        text = re.sub(pattern, replacement, text)

    def measure(match):
        dimension, factor = UNITS[match[2]]
        amount = Decimal(match[1]) * factor
        return f" {dimension}{format(amount.normalize(), 'f')} "

    text = re.sub(r"\b(\d+(?:\.\d+)?)\s*[- ]?(fl oz|ml|kg|oz|lb|cm|mm|in|g|l)\b", measure, text)
    # Ignore grammar only. Additional colors, flavors, generations and accessories must still reject.
    return set(re.findall(r"[^\W_]+(?:\.[0-9]+)?", text, re.UNICODE)) - {"the", "a", "of", "and"}


def scalar(value):
    if isinstance(value, dict):
        value = value.get("name") or value.get("value")
    return str(value)[:300] if isinstance(value, (str, int, float)) else ""


def product_attributes(node):
    result = {k: scalar(node.get(k)) for k in ("name", "brand", "model", "size", "color")}
    result["model"] = result["model"] or scalar(node.get("mpn"))
    for prop in node.get("additionalProperty", []) if isinstance(node.get("additionalProperty", []), list) else []:
        if not isinstance(prop, dict):
            continue
        name = normalized(prop.get("name", ""))
        field = {
            "flavor": "variant",
            "flavour": "variant",
            "variant": "variant",
            "size": "size",
            "color": "color",
            "colour": "color",
            "pack count": "pack_count",
            "number of items": "pack_count",
        }.get(name)
        if field:
            value = scalar(prop.get("value"))
            if result.get(field) and normalized(result[field]) != normalized(value):
                result["conflict"] = True
            result[field] = value
    codes = {gtin(node.get(k, "")) for k in ("gtin", "gtin8", "gtin12", "gtin13", "gtin14")}
    result["gtins"] = sorted(c for c in codes if c)
    return result


def derive_identity(identity, source):
    # Promote only source attributes literally present in the user's item name. No invented details.
    values = identity.model_dump(exclude_none=True)
    for field in ("brand", "model", "variant", "size", "color"):
        value = source.get(field)
        if field == "model" and value and not (re.search(r"[a-z]", value.casefold()) and re.search(r"[0-9]", value)):
            continue  # A bare number in a name is not evidence that it is the model number.
        if not values.get(field) and value and canonical(value) <= canonical(identity.name):
            values[field] = value
    pack = re.search(r"\b(\d+)\s*[- ]?(?:pack|pk|count|ct)\b|\bpack of (\d+)\b", identity.name.casefold())
    if not values.get("pack_count") and pack:
        count = int(pack[1] or pack[2])
        if 1 <= count <= 1000:
            values["pack_count"] = count
    return ImageIdentity.model_validate(values)


def verify_product(identity, node):
    """Return auditable evidence only for an exact identifier or complete attribute match."""
    source = product_attributes(node)
    identity = derive_identity(identity, source)
    if identity.missing() or source.get("conflict") or not source["name"]:
        return None
    expected = identity.model_dump(exclude_none=True)
    # A ProductGroup is never a specific variant. Product variants need their own image and identity.
    for field in ("brand", "model", "variant", "size", "color"):
        wanted, observed = expected.get(field), source.get(field)
        if wanted and observed and canonical(wanted) != canonical(observed):
            return None
        if wanted and not observed and not canonical(wanted) <= canonical(source["name"]):
            return None
    source_text = " ".join(source.get(k, "") for k in ("name", "brand", "model", "variant", "size", "color"))
    if source.get("pack_count"):
        source_text += f" {source['pack_count']} pack"
    if identity.pack_count:
        if source.get("pack_count") and source["pack_count"] != str(identity.pack_count):
            return None
        title_packs = re.findall(r"\b(\d+)\s*[- ]?(?:pack|pk|count|ct)\b|\bpack of (\d+)\b", source["name"].casefold())
        if any(int(a or b) != identity.pack_count for a, b in title_packs):
            return None
        if not canonical(f"{identity.pack_count} pack") <= canonical(source_text):
            return None
    if identity.size:
        for dimension in ("volume", "mass", "length"):
            wanted = {v for v in canonical(identity.size) if v.startswith(dimension)}
            observed = {v for v in canonical(source_text) if v.startswith(dimension)}
            if wanted and observed != wanted:
                return None
    if identity.gtin:
        if source["gtins"] != [identity.gtin]:
            return None
        # Even an identifier cannot override explicit contradictory name/variant evidence.
        if not canonical(identity.name) <= canonical(source_text):
            return None
        basis = "gtin"
    else:
        expected_text = " ".join(str(v) for k, v in expected.items() if k not in ("gtin", "pack_count"))
        if identity.pack_count:
            expected_text += f" {identity.pack_count} pack"
        if canonical(expected_text) != canonical(source_text):
            return None
        basis = "brand_model" if identity.model else "complete_variant"
    return {
        "version": VERIFICATION_VERSION,
        "status": "exact",
        "basis": basis,
        "requested": expected,
        "observed": source,
        "image_binding": "Product.image",
        "visual_check": "not_performed",
    }


# Aliases are search hints, not permission to accept a different generation or variant.
# Official product landing pages supply useful evidence even when they omit JSON-LD.
PRODUCT_HINTS = (
    (r"\b(?:ps5|playstation\s*5)\b", "PlayStation 5", "Sony", "https://www.playstation.com/en-us/ps5/"),
    (
        r"\b(?:xsx|xbox\s+series\s+x)\b",
        "Xbox Series X",
        "Microsoft",
        "https://www.xbox.com/en-US/consoles/xbox-series-x",
    ),
)
SEARCH_VERSION = 3


def expanded_name(text):
    text = re.sub(r"[®™]", "", text).casefold()
    for pattern, name, _, _ in PRODUCT_HINTS:
        text = re.sub(pattern, name.casefold(), text)
    return text


def search_queries(identity):
    original = identity.query()
    expanded = expanded_name(original)
    return list(dict.fromkeys([original, expanded if expanded != original.casefold() else original + " product image"]))


def official_pages(identity):
    return [url for pattern, _, _, url in PRODUCT_HINTS if re.search(pattern, identity.name, re.I)]


def name_words(text):
    return set(re.findall(r"[^\W_]+", expanded_name(text), re.UNICODE)) - {"a", "the", "of", "and"}


def image_rank(image):
    """Choose a useful default without relabeling a plausible image as an exact SKU match."""
    evidence = image.get("verification") or {}
    requested = evidence.get("requested") or {}
    title = evidence.get("title") or evidence.get("observed", {}).get("name", "")
    extra = name_words(title) - name_words(requested.get("name", ""))
    official = any(
        re.search(pattern, requested.get("name", ""), re.I)
        and (image.get("source_url") or "").rstrip("/").casefold() == url.rstrip("/").casefold()
        for pattern, _, _, url in PRODUCT_HINTS
    )
    return (
        evidence.get("status") != "exact",
        not official,
        {"Product.image": 0, "img.alt": 1, "og:image": 2}.get(evidence.get("image_binding"), 3),
        len(extra & {"bundle", "special", "limited", "pro", "digital", "refurbished", "renewed", "used"}),
    )


def assess_product(identity, node, *, binding="Product.image", official=False):
    """Discovery accepts incomplete names; evidence records exact identity versus a plausible product match."""
    strict = verify_product(identity, node) if binding == "Product.image" else None
    if strict:
        return strict
    source = product_attributes(node)
    wanted, actual = name_words(identity.name), name_words(source["name"])
    if not wanted or not wanted <= actual or source.get("conflict"):
        return None
    # An accessory mentioning the console is not the console. Likewise games, logos and comparison shots.
    accessory = {
        "case",
        "cover",
        "sleeve",
        "skin",
        "stand",
        "charger",
        "controller",
        "remote",
        "game",
        "games",
        "accessory",
        "accessories",
        "logo",
        "badge",
        "replacement",
        "compatible",
    }
    extra = actual - wanted
    if extra & accessory:
        # Manufacturer console photos often include the supplied controller in the same product shot.
        before_with = re.split(r"\bwith\b", source["name"], flags=re.I)[0]
        if not (
            official
            and re.search(r"\bwith\b", source["name"], re.I)
            and extra & accessory <= {"controller"}
            and wanted <= name_words(before_with)
        ):
            return None
    if extra & {
        "collection",
        "selection",
        "showing",
        "menu",
        "animated",
        "sketch",
        "box",
        "backgrounds",
        "branded",
        "panel",
    }:
        return None
    for field in ("brand", "model", "variant", "size", "color"):
        expected, observed = getattr(identity, field), source.get(field)
        if expected and observed and canonical(expected) != canonical(observed):
            return None
        if (
            expected
            and not observed
            and not canonical(expanded_name(expected)) <= canonical(expanded_name(source["name"]))
        ):
            return None
    if identity.gtin and source["gtins"] and source["gtins"] != [identity.gtin]:
        return None
    if identity.pack_count and source.get("pack_count") and source["pack_count"] != str(identity.pack_count):
        return None
    title_packs = re.findall(r"\b(\d+)\s*[- ]?(?:pack|pk|count|ct)\b|\bpack of (\d+)\b", source["name"].casefold())
    if identity.pack_count and any(int(a or b) != identity.pack_count for a, b in title_packs):
        return None
    # Explicit quantities/generations must agree; unknown variants become choices, never invented facts.
    if identity.size:
        source_size = canonical(" ".join(source.get(k, "") for k in ("name", "size")))
        if not canonical(identity.size) <= source_size:
            return None
        for dimension in ("volume", "mass", "length"):
            expected = {v for v in canonical(identity.size) if v.startswith(dimension)}
            if expected and {v for v in source_size if v.startswith(dimension)} != expected:
                return None
    variants = {
        "pro",
        "slim",
        "digital",
        "edition",
        "bundle",
        "refurbished",
        "renewed",
        "used",
        "white",
        "black",
        "red",
        "blue",
        "silver",
        "gold",
        "green",
        "pink",
        "mini",
        "max",
        "plus",
        "lite",
    }
    # A specific requested edition cannot silently become another edition.
    for group in ({"white", "black", "red", "blue", "silver", "gold", "green", "pink"},):
        if wanted & group and actual & group and wanted & group != actual & group:
            return None
    ignored = {
        "console",
        "sony",
        "microsoft",
        "product",
        "image",
        "photo",
        "left",
        "right",
        "angle",
        "laying",
        "horizontal",
        "vertical",
        "standing",
        "vertically",
        "horizontally",
    }
    named_brand = bool(source["brand"] and name_words(source["brand"]) <= wanted)
    known_name = any(re.search(pattern, identity.name, re.I) for pattern, _, _, _ in PRODUCT_HINTS)
    unspecified = [
        field
        for field in ("variant", "size", "color", "pack_count")
        if source.get(field) and not getattr(identity, field) and not name_words(source[field]) <= wanted
    ]
    exact_name = actual - ignored == wanted - ignored
    automatic = ((binding == "Product.image" and named_brand) or (official and known_name)) and exact_name
    automatic = automatic and not unspecified and not extra & variants and not identity.gtin
    return {
        "version": VERIFICATION_VERSION,
        "status": "exact" if automatic else "candidate",
        "basis": "product_name" if automatic else "name_candidate",
        "requested": identity.model_dump(exclude_none=True),
        "observed": source,
        "image_binding": binding,
        "visual_check": "not_performed",
        "scope": "named_product" if automatic else "name_candidate",
        "title": source["name"],
        "missing_attributes": unspecified,
    }
