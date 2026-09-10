import os
import sqlite3
from flask import Flask, jsonify, request

app = Flask(__name__)
DB_PATH = "users.db"


def get_db():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    conn = get_db()
    conn.execute(
        "CREATE TABLE IF NOT EXISTS users (id INTEGER PRIMARY KEY, username TEXT, email TEXT)"
    )
    conn.execute("DELETE FROM users")
    conn.executemany(
        "INSERT INTO users (username, email) VALUES (?, ?)",
        [("alice", "alice@example.com"), ("bob", "bob@example.com")],
    )
    conn.commit()
    conn.close()


@app.route("/")
def index():
    return jsonify({"status": "ok", "service": "security-pipeline-demo"})


@app.route("/health")
def health():
    return jsonify({"status": "healthy"})


@app.route("/users/<username>")
def get_user(username):
    conn = get_db()
    row = conn.execute(
        "SELECT id, username, email FROM users WHERE username = ?", (username,)
    ).fetchone()
    conn.close()
    if row is None:
        return jsonify({"error": "not found"}), 404
    return jsonify({"id": row["id"], "username": row["username"], "email": row["email"]})


if __name__ == "__main__":
    init_db()
    # Bind to localhost by default. Set FLASK_HOST=0.0.0.0 explicitly
    # if the app genuinely needs to be reachable from other machines.
    host = os.environ.get("FLASK_HOST", "127.0.0.1")
    app.run(debug=False, host=host, port=5000)