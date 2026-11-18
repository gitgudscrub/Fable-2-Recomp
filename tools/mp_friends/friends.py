#!/usr/bin/env python3
"""Fable II co-op friends service (f53): accounts, friends, presence, invites.

Runs on the home server behind the Cloudflare tunnel (HTTPS). Python standard
library only. Data lives in one SQLite file.

  * Accounts: username + password. Passwords are hashed with scrypt; sign-in
    hands back a random token (only its SHA-256 is stored), valid 90 days.
  * Friends: send a request by username; the other player accepts it.
  * Presence: the launcher reports every 30 s whether its player is online or
    in a co-op session (and the session's invite code). Shown to friends only.
  * Invites: a player in a session can invite a friend; the friend's launcher
    picks it up and joins. Invites expire after 10 minutes.
  * Limits: sign-up and sign-in attempts per address, request sizes, friend
    and request counts.

The relay address players should use is handed out by GET /config, so players
never type it in. JSON API, see the handlers below. Tests: test_friends.py.

Usage: python friends.py --db friends.sqlite --port 18090 --relay host:port
"""
from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import logging
import re
import secrets
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

log = logging.getLogger("friends")

USERNAME_RE = re.compile(r"^[A-Za-z0-9_]{3,20}$")
CODE_RE = re.compile(r"^[A-Z0-9]{4,8}$")
MIN_PASSWORD, MAX_PASSWORD = 8, 128
TOKEN_DAYS = 90
ONLINE_FOR = 90          # seconds since the last presence report
INVITE_FOR = 600         # seconds an invite stays valid
MAX_FRIENDS = 200
MAX_PENDING_OUT = 50
MAX_BODY = 4096
SCRYPT = dict(n=2**14, r=8, p=1, dklen=32)
# per address: sign-up / sign-in attempts (burst, per second)
AUTH_BURST, AUTH_RATE = 10, 1 / 30
REGISTER_BURST, REGISTER_RATE = 3, 1 / 600

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  name_key TEXT NOT NULL UNIQUE,
  pw_salt BLOB NOT NULL,
  pw_hash BLOB NOT NULL,
  created REAL NOT NULL,
  last_seen REAL NOT NULL DEFAULT 0,
  status TEXT NOT NULL DEFAULT 'offline',
  session_code TEXT NOT NULL DEFAULT ''
);
CREATE TABLE IF NOT EXISTS tokens (
  hash BLOB PRIMARY KEY,
  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires REAL NOT NULL
);
CREATE TABLE IF NOT EXISTS friends (
  a INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  b INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  since REAL NOT NULL,
  PRIMARY KEY (a, b)
);
CREATE TABLE IF NOT EXISTS requests (
  src INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  dst INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created REAL NOT NULL,
  PRIMARY KEY (src, dst)
);
CREATE TABLE IF NOT EXISTS invites (
  id INTEGER PRIMARY KEY,
  src INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  dst INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  code TEXT NOT NULL,
  created REAL NOT NULL
);
"""


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status, self.message = status, message


class Bucket:
    def __init__(self, rate: float, burst: float):
        self.rate, self.burst, self.level, self.t = rate, burst, burst, time.monotonic()

    def take(self) -> bool:
        now = time.monotonic()
        self.level = min(self.burst, self.level + (now - self.t) * self.rate)
        self.t = now
        if self.level < 1:
            return False
        self.level -= 1
        return True


def hash_password(password: str, salt: bytes) -> bytes:
    return hashlib.scrypt(password.encode("utf-8"), salt=salt, maxmem=64 * 1024 * 1024, **SCRYPT)


def token_hash(token: str) -> bytes:
    return hashlib.sha256(token.encode("ascii", "replace")).digest()


class Service:
    """All the rules, independent of HTTP (so tests can call it directly)."""

    def __init__(self, db_path: str, relay: str):
        self.relay = relay
        self.db = sqlite3.connect(db_path, check_same_thread=False, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.execute("PRAGMA journal_mode = WAL")
        self.db.executescript(SCHEMA)
        self.lock = threading.Lock()
        self.limits: dict[tuple, Bucket] = {}
        self._dummy_salt = secrets.token_bytes(16)

    # --- helpers -------------------------------------------------------------
    def _limit(self, kind: str, ip: str, burst: float, rate: float):
        key = (kind, ip)
        b = self.limits.get(key)
        if b is None:
            if len(self.limits) > 50000:
                self.limits.clear()
            b = self.limits[key] = Bucket(rate, burst)
        if not b.take():
            raise ApiError(429, "Too many attempts. Wait a few minutes and try again.")

    def _user_by_name(self, name) -> sqlite3.Row | None:
        if not isinstance(name, str) or not USERNAME_RE.match(name):
            return None
        return self.db.execute("SELECT * FROM users WHERE name_key = ?", (name.lower(),)).fetchone()

    def _are_friends(self, a: int, b: int) -> bool:
        return self.db.execute("SELECT 1 FROM friends WHERE a = ? AND b = ?", (a, b)).fetchone() is not None

    def _issue_token(self, user_id: int) -> str:
        token = secrets.token_urlsafe(32)
        self.db.execute("INSERT INTO tokens (hash, user_id, expires) VALUES (?, ?, ?)",
                        (token_hash(token), user_id, time.time() + TOKEN_DAYS * 86400))
        return token

    @staticmethod
    def _str(body: dict, key: str, max_len: int = 200) -> str:
        v = body.get(key)
        if not isinstance(v, str) or len(v) > max_len:
            raise ApiError(400, f"'{key}' is missing or too long.")
        return v

    def _presence(self, row) -> dict:
        online = time.time() - row["last_seen"] < ONLINE_FOR
        status = row["status"] if online else "offline"
        return {"name": row["name"], "status": status,
                "in_session": online and status == "playing" and bool(row["session_code"])}

    # --- accounts --------------------------------------------------------------
    def register(self, body: dict, ip: str) -> dict:
        name = self._str(body, "username", 40)
        password = self._str(body, "password", MAX_PASSWORD)
        if not USERNAME_RE.match(name):
            raise ApiError(400, "Usernames are 3 to 20 letters, numbers or _.")
        if len(password) < MIN_PASSWORD:
            raise ApiError(400, f"Passwords need at least {MIN_PASSWORD} characters.")
        self._limit("register", ip, REGISTER_BURST, REGISTER_RATE)
        salt = secrets.token_bytes(16)
        pw = hash_password(password, salt)
        with self.lock:
            try:
                cur = self.db.execute(
                    "INSERT INTO users (name, name_key, pw_salt, pw_hash, created) VALUES (?, ?, ?, ?, ?)",
                    (name, name.lower(), salt, pw, time.time()))
            except sqlite3.IntegrityError:
                raise ApiError(409, "That username is taken.")
            token = self._issue_token(cur.lastrowid)
        log.info("account created: %s", name)
        return {"token": token, "username": name}

    def login(self, body: dict, ip: str) -> dict:
        name = self._str(body, "username", 40)
        password = self._str(body, "password", MAX_PASSWORD)
        self._limit("login", ip, AUTH_BURST, AUTH_RATE)
        row = self._user_by_name(name)
        # hash even for unknown names so timing doesn't reveal which names exist
        pw = hash_password(password, row["pw_salt"] if row else self._dummy_salt)
        if row is None or not hmac.compare_digest(pw, row["pw_hash"]):
            raise ApiError(401, "Wrong username or password.")
        with self.lock:
            return {"token": self._issue_token(row["id"]), "username": row["name"]}

    def auth(self, header: str | None) -> sqlite3.Row:
        if not header or not header.startswith("Bearer "):
            raise ApiError(401, "Sign in first.")
        row = self.db.execute(
            "SELECT users.* FROM tokens JOIN users ON users.id = tokens.user_id "
            "WHERE tokens.hash = ? AND tokens.expires > ?",
            (token_hash(header[7:].strip()), time.time())).fetchone()
        if row is None:
            raise ApiError(401, "Your sign-in has expired. Sign in again.")
        return row

    def logout(self, header: str) -> dict:
        self.db.execute("DELETE FROM tokens WHERE hash = ?", (token_hash(header[7:].strip()),))
        return {}

    def change_password(self, me, body: dict) -> dict:
        old = self._str(body, "old_password", MAX_PASSWORD)
        new = self._str(body, "new_password", MAX_PASSWORD)
        if not hmac.compare_digest(hash_password(old, me["pw_salt"]), me["pw_hash"]):
            raise ApiError(401, "Your current password is wrong.")
        if len(new) < MIN_PASSWORD:
            raise ApiError(400, f"Passwords need at least {MIN_PASSWORD} characters.")
        salt = secrets.token_bytes(16)
        with self.lock:
            self.db.execute("UPDATE users SET pw_salt = ?, pw_hash = ? WHERE id = ?",
                            (salt, hash_password(new, salt), me["id"]))
            self.db.execute("DELETE FROM tokens WHERE user_id = ?", (me["id"],))  # sign out everywhere
            return {"token": self._issue_token(me["id"])}

    def delete_account(self, me, body: dict) -> dict:
        password = self._str(body, "password", MAX_PASSWORD)
        if not hmac.compare_digest(hash_password(password, me["pw_salt"]), me["pw_hash"]):
            raise ApiError(401, "Wrong password.")
        with self.lock:
            self.db.execute("DELETE FROM users WHERE id = ?", (me["id"],))
        log.info("account deleted: %s", me["name"])
        return {}

    # --- friends ---------------------------------------------------------------
    def friends(self, me) -> dict:
        rows = self.db.execute(
            "SELECT users.* FROM friends JOIN users ON users.id = friends.b WHERE friends.a = ? "
            "ORDER BY users.name_key", (me["id"],)).fetchall()
        incoming = self.db.execute(
            "SELECT users.name FROM requests JOIN users ON users.id = requests.src WHERE requests.dst = ? "
            "ORDER BY requests.created", (me["id"],)).fetchall()
        outgoing = self.db.execute(
            "SELECT users.name FROM requests JOIN users ON users.id = requests.dst WHERE requests.src = ? "
            "ORDER BY requests.created", (me["id"],)).fetchall()
        return {"username": me["name"], "friends": [self._presence(r) for r in rows],
                "incoming": [r["name"] for r in incoming], "outgoing": [r["name"] for r in outgoing]}

    def request(self, me, body: dict) -> dict:
        other = self._user_by_name(self._str(body, "username", 40))
        if other is None:
            raise ApiError(404, "No player with that username.")
        if other["id"] == me["id"]:
            raise ApiError(400, "That's you.")
        with self.lock:
            if self._are_friends(me["id"], other["id"]):
                return {"result": "already friends"}
            # they already asked us: accept straight away
            if self.db.execute("SELECT 1 FROM requests WHERE src = ? AND dst = ?",
                               (other["id"], me["id"])).fetchone():
                self._make_friends(me["id"], other["id"])
                return {"result": "friends"}
            n_out = self.db.execute("SELECT COUNT(*) FROM requests WHERE src = ?", (me["id"],)).fetchone()[0]
            if n_out >= MAX_PENDING_OUT:
                raise ApiError(429, "You have too many unanswered requests.")
            self._check_room(me["id"])
            self.db.execute("INSERT OR IGNORE INTO requests (src, dst, created) VALUES (?, ?, ?)",
                            (me["id"], other["id"], time.time()))
        return {"result": "requested"}

    def _check_room(self, uid: int):
        if self.db.execute("SELECT COUNT(*) FROM friends WHERE a = ?", (uid,)).fetchone()[0] >= MAX_FRIENDS:
            raise ApiError(429, f"Friends lists hold up to {MAX_FRIENDS} players.")

    def _make_friends(self, a: int, b: int):
        self._check_room(a)
        self._check_room(b)
        now = time.time()
        self.db.execute("DELETE FROM requests WHERE (src = ? AND dst = ?) OR (src = ? AND dst = ?)", (a, b, b, a))
        self.db.execute("INSERT OR IGNORE INTO friends (a, b, since) VALUES (?, ?, ?)", (a, b, now))
        self.db.execute("INSERT OR IGNORE INTO friends (a, b, since) VALUES (?, ?, ?)", (b, a, now))

    def accept(self, me, body: dict) -> dict:
        other = self._user_by_name(self._str(body, "username", 40))
        with self.lock:
            if other is None or not self.db.execute(
                    "SELECT 1 FROM requests WHERE src = ? AND dst = ?", (other["id"], me["id"])).fetchone():
                raise ApiError(404, "No friend request from that player.")
            self._make_friends(me["id"], other["id"])
        return {"result": "friends"}

    def remove(self, me, body: dict) -> dict:
        """Unfriend, decline a request or cancel our own request."""
        other = self._user_by_name(self._str(body, "username", 40))
        if other is None:
            return {}
        a, b = me["id"], other["id"]
        with self.lock:
            self.db.execute("DELETE FROM friends WHERE (a = ? AND b = ?) OR (a = ? AND b = ?)", (a, b, b, a))
            self.db.execute("DELETE FROM requests WHERE (src = ? AND dst = ?) OR (src = ? AND dst = ?)", (a, b, b, a))
            self.db.execute("DELETE FROM invites WHERE (src = ? AND dst = ?) OR (src = ? AND dst = ?)", (a, b, b, a))
        return {}

    # --- presence and invites ----------------------------------------------------
    def presence(self, me, body: dict) -> dict:
        status = body.get("status")
        if status not in ("online", "playing", "offline"):
            raise ApiError(400, "'status' must be online, playing or offline.")
        code = body.get("session_code") or ""
        if not isinstance(code, str) or (code and not CODE_RE.match(code)):
            raise ApiError(400, "Bad session code.")
        if status != "playing":
            code = ""
        seen = 0 if status == "offline" else time.time()
        with self.lock:
            self.db.execute("UPDATE users SET last_seen = ?, status = ?, session_code = ? WHERE id = ?",
                            (seen, status, code, me["id"]))
        return {}

    def invite(self, me, body: dict) -> dict:
        other = self._user_by_name(self._str(body, "username", 40))
        if other is None or not self._are_friends(me["id"], other["id"]):
            raise ApiError(404, "You can only invite friends.")
        if not (me["status"] == "playing" and me["session_code"] and time.time() - me["last_seen"] < ONLINE_FOR):
            raise ApiError(409, "Start or join a co-op game first.")
        with self.lock:
            self.db.execute("DELETE FROM invites WHERE src = ? AND dst = ?", (me["id"], other["id"]))
            self.db.execute("INSERT INTO invites (src, dst, code, created) VALUES (?, ?, ?, ?)",
                            (me["id"], other["id"], me["session_code"], time.time()))
        return {"result": "invited"}

    def invites(self, me) -> dict:
        now = time.time()
        with self.lock:
            self.db.execute("DELETE FROM invites WHERE created < ?", (now - INVITE_FOR,))
        rows = self.db.execute(
            "SELECT invites.id, invites.code, invites.created, users.name FROM invites "
            "JOIN users ON users.id = invites.src WHERE invites.dst = ? ORDER BY invites.created",
            (me["id"],)).fetchall()
        return {"invites": [{"id": r["id"], "from": r["name"], "code": r["code"],
                             "age": int(now - r["created"])} for r in rows]}

    def dismiss(self, me, body: dict) -> dict:
        iid = body.get("id")
        if not isinstance(iid, int):
            raise ApiError(400, "'id' must be a number.")
        with self.lock:
            self.db.execute("DELETE FROM invites WHERE id = ? AND dst = ?", (iid, me["id"]))
        return {}

    def config(self) -> dict:
        return {"relay": self.relay, "min_password": MIN_PASSWORD}


def make_handler(svc: Service, trust_cf_ip: bool):
    routes_public = {
        ("POST", "/v1/register"): lambda s, b, ip, h: svc.register(b, ip),
        ("POST", "/v1/login"): lambda s, b, ip, h: svc.login(b, ip),
        ("GET", "/v1/config"): lambda s, b, ip, h: svc.config(),
    }
    routes_auth = {
        ("POST", "/v1/logout"): lambda me, b, h: svc.logout(h),
        ("POST", "/v1/password"): lambda me, b, h: svc.change_password(me, b),
        ("POST", "/v1/delete-account"): lambda me, b, h: svc.delete_account(me, b),
        ("GET", "/v1/friends"): lambda me, b, h: svc.friends(me),
        ("POST", "/v1/friends/request"): lambda me, b, h: svc.request(me, b),
        ("POST", "/v1/friends/accept"): lambda me, b, h: svc.accept(me, b),
        ("POST", "/v1/friends/remove"): lambda me, b, h: svc.remove(me, b),
        ("POST", "/v1/presence"): lambda me, b, h: svc.presence(me, b),
        ("POST", "/v1/invite"): lambda me, b, h: svc.invite(me, b),
        ("GET", "/v1/invites"): lambda me, b, h: svc.invites(me),
        ("POST", "/v1/invites/dismiss"): lambda me, b, h: svc.dismiss(me, b),
    }

    class Handler(BaseHTTPRequestHandler):
        server_version = "fable2-friends"
        sys_version = ""

        def log_message(self, fmt, *args):  # keep request logs (and tokens) out
            pass

        def _send(self, status: int, payload: dict):
            data = json.dumps(payload).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _handle(self, method: str):
            try:
                path = self.path.split("?", 1)[0]
                body = {}
                if method == "POST":
                    n = int(self.headers.get("Content-Length") or 0)
                    if n < 0 or n > MAX_BODY:
                        raise ApiError(413, "Request too large.")
                    raw = self.rfile.read(n) if n else b"{}"
                    try:
                        body = json.loads(raw or b"{}")
                    except ValueError:
                        raise ApiError(400, "Body must be JSON.")
                    if not isinstance(body, dict):
                        raise ApiError(400, "Body must be a JSON object.")
                ip = self.client_address[0]
                if trust_cf_ip and self.headers.get("CF-Connecting-IP"):
                    ip = self.headers["CF-Connecting-IP"]
                key = (method, path)
                if key in routes_public:
                    return self._send(200, routes_public[key](self, body, ip, None))
                if key in routes_auth:
                    h = self.headers.get("Authorization")
                    me = svc.auth(h)
                    return self._send(200, routes_auth[key](me, body, h))
                raise ApiError(404, "Not found.")
            except ApiError as e:
                self._send(e.status, {"error": e.message})
            except Exception:
                log.exception("request failed")
                self._send(500, {"error": "Server error."})

        def do_GET(self):
            self._handle("GET")

        def do_POST(self):
            self._handle("POST")

    return Handler


def serve(db: str, bind: str, port: int, relay: str, trust_cf_ip: bool):
    svc = Service(db, relay)
    httpd = ThreadingHTTPServer((bind, port), make_handler(svc, trust_cf_ip))
    log.info("friends service on http://%s:%d (relay %s)", bind, port, relay or "not set")
    httpd.serve_forever()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--db", default="friends.sqlite")
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=18090)
    ap.add_argument("--relay", default="", help="relay host:port handed to players")
    ap.add_argument("--trust-cf-ip", action="store_true",
                    help="use the CF-Connecting-IP header for rate limits (only behind Cloudflare)")
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    serve(args.db, args.bind, args.port, args.relay, args.trust_cf_ip)


if __name__ == "__main__":
    main()
