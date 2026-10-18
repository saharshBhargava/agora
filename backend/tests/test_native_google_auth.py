import hashlib
import time
from types import SimpleNamespace
from uuid import uuid4

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives.asymmetric import rsa

from app.auth import TokenVerifier, ensure_user
from app.config import Settings
from app.errors import Problem
from app.main import create_app

CLIENT_ID = "123-native.apps.googleusercontent.com"


@pytest.fixture(scope="module")
def signing_key():
    return rsa.generate_private_key(public_exponent=65537, key_size=2048)


def verifier_with_key(settings, key):
    verifier = TokenVerifier(settings)
    verifier._jwks = SimpleNamespace(get_signing_key_from_jwt=lambda _: SimpleNamespace(key=key.public_key()))
    return verifier


def token(key, **claims):
    now = int(time.time())
    return jwt.encode({"iss": "https://accounts.google.com", "aud": CLIENT_ID, "sub": "google-subject",
                       "iat": now, "exp": now + 3600, **claims}, key, algorithm="RS256")


def test_native_configuration_requires_no_server_oauth_secrets():
    settings = Settings(env="prod", auth_mode="google", google_ios_client_id=CLIENT_ID)
    assert settings.google_client_secret is None
    assert settings.google_token_key is None
    assert settings.google_redirect_uri is None


def test_google_identity_verified_and_namespaced(signing_key):
    verifier = verifier_with_key(Settings(auth_mode="google", google_ios_client_id=CLIENT_ID), signing_key)
    assert verifier.verify(token(signing_key)) == "google:google-subject"
    assert verifier.verify(token(signing_key, iss="accounts.google.com")) == "google:google-subject"
    assert verifier.verify(token(signing_key, azp=CLIENT_ID)) == "google:google-subject"


@pytest.mark.parametrize("claims", [
    {"aud": "other-client"}, {"iss": "https://attacker.example.com"}, {"exp": 1},
    {"iat": 9999999999}, {"sub": ""}, {"azp": "other-client"},
])
def test_wrong_identity_claims_rejected(signing_key, claims):
    verifier = verifier_with_key(Settings(auth_mode="google", google_ios_client_id=CLIENT_ID), signing_key)
    with pytest.raises(Problem) as error:
        verifier.verify(token(signing_key, **claims))
    assert error.value.status == 401


def test_invalid_signature_and_unsigned_token_rejected(signing_key):
    verifier = verifier_with_key(Settings(auth_mode="google", google_ios_client_id=CLIENT_ID), signing_key)
    attacker_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    with pytest.raises(Problem):
        verifier.verify(token(attacker_key))
    with pytest.raises(Problem):
        verifier.verify(jwt.encode({"sub": "google-subject"}, "", algorithm="none"))


async def test_native_inventory_preserves_existing_account_and_isolation(database_url, tmp_path, signing_key):
    settings = Settings(env="test", auth_mode="google", google_ios_client_id=CLIENT_ID,
                        database_url=database_url, storage_dir=tmp_path, run_worker_in_process=False)
    app = create_app(settings)
    async with app.router.lifespan_context(app):
        app.state.verifier = verifier_with_key(settings, signing_key)
        subject = uuid4().hex
        # Same subject/handle as a previous server-side Google Calendar sign-in.
        user_id = await ensure_user(app.state.db, "google:" + subject,
                                    "g_" + hashlib.sha256(subject.encode()).hexdigest()[:28], "Existing user")
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url="https://test") as client:
            headers = {"Authorization": "Bearer " + token(signing_key, sub=subject)}
            me = await client.get("/v1/me", headers=headers)
            assert me.status_code == 200 and me.json()["id"] == str(user_id)
            inventory = await client.get("/v1/inventory", headers=headers)
            assert inventory.status_code == 200
            household = me.json()["households"][0]["id"]
            created = await client.post("/v1/inventory", headers=headers, json={
                "household_id": household, "display_name": "Milk", "quantity": 1})
            assert created.status_code == 201
            other = {"Authorization": "Bearer " + token(signing_key, sub=uuid4().hex)}
            assert (await client.get(f"/v1/inventory/{created.json()['id']}", headers=other)).status_code == 404
            assert (await client.get("/v1/inventory", headers=other)).json() == []
            async with app.state.db.system() as conn:
                assert not await conn.fetchval("SELECT 1 FROM google_calendar_connections WHERE user_id = $1", user_id)
                await conn.execute("UPDATE users SET deleted_at = now() WHERE id = $1", user_id)
            assert (await client.get("/v1/me", headers=headers)).status_code == 401


def test_seeding_new_users_is_local_dev_only():
    # Hosted deploys (demo or prod) must never give real accounts mock data; they use the demo account instead.
    for env in ("prod", "demo"):
        with pytest.raises(ValueError, match="SEED_NEW_USERS"):
            Settings(env=env, auth_mode="google", google_ios_client_id=CLIENT_ID, seed_new_users=True)
