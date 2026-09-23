#!/usr/bin/env bash
# Pilot fixture: a notes API; the change adds GET /notes/<id> with no ownership check.
set -euo pipefail
git init -q -b main
git config user.email eval@example.invalid
git config user.name eval

cat > app.py <<'PY'
from flask import Flask, g, jsonify, abort, request
import db

app = Flask(__name__)


@app.before_request
def authenticate():
    user = db.user_for_token(request.headers.get("Authorization", "").removeprefix("Bearer "))
    if user is None:
        abort(401)
    g.user = user


@app.get("/notes")
def list_notes():
    return jsonify(db.query("SELECT id, title FROM notes WHERE owner_id = ?", g.user.id))
PY
cat > db.py <<'PY'
import sqlite3

conn = sqlite3.connect("notes.db", check_same_thread=False)


def query(sql, *args):
    return [dict(zip([c[0] for c in cur.description], row))
            for cur in [conn.execute(sql, args)] for row in cur.fetchall()]


def user_for_token(token):
    rows = query("SELECT id FROM users WHERE api_token = ?", token)
    return type("User", (), rows[0]) if rows else None
PY
git add -A && git commit -q -m "Notes API: list own notes"

git checkout -q -b feature/read-note
cat >> app.py <<'PY'


@app.get("/notes/<int:note_id>")
def read_note(note_id):
    rows = db.query("SELECT id, title, body FROM notes WHERE id = ?", note_id)
    if not rows:
        abort(404)
    return jsonify(rows[0])
PY
git commit -q -am "Read a single note by id"
