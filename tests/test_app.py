import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))

import pytest
from app import app, init_db


@pytest.fixture
def client():
    init_db()
    app.config["TESTING"] = True
    with app.test_client() as client:
        yield client


def test_index(client):
    resp = client.get("/")
    assert resp.status_code == 200
    assert resp.get_json()["status"] == "ok"


def test_health(client):
    resp = client.get("/health")
    assert resp.status_code == 200


def test_get_existing_user(client):
    resp = client.get("/users/alice")
    assert resp.status_code == 200
    assert resp.get_json()["username"] == "alice"


def test_get_missing_user(client):
    resp = client.get("/users/nobody")
    assert resp.status_code == 404
