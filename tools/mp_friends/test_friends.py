"""Tests for friends.py over real HTTP on localhost: python -m unittest test_friends (from this folder)."""
import json
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer

import friends as F


class FriendsTest(unittest.TestCase):
    def setUp(self):
        F.REGISTER_BURST = 100  # tests make many accounts from one address
        self.svc = F.Service(":memory:", "relay.example:27970")
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), F.make_handler(self.svc, False))
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()

    def call(self, method, path, body=None, token=None, raw=None):
        data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(f"http://127.0.0.1:{self.port}{path}", data=data, method=method)
        if token:
            req.add_header("Authorization", "Bearer " + token)
        req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())

    def account(self, name, password="correct horse"):
        st, r = self.call("POST", "/v1/register", {"username": name, "password": password})
        self.assertEqual(st, 200, r)
        return r["token"]

    def test_register_login_rules(self):
        self.account("Alice")
        self.assertEqual(self.call("POST", "/v1/register", {"username": "alice", "password": "12345678"})[0], 409)
        self.assertEqual(self.call("POST", "/v1/register", {"username": "a b", "password": "12345678"})[0], 400)
        self.assertEqual(self.call("POST", "/v1/register", {"username": "bob", "password": "short"})[0], 400)
        st, r = self.call("POST", "/v1/login", {"username": "ALICE", "password": "correct horse"})
        self.assertEqual((st, r["username"]), (200, "Alice"))
        self.assertEqual(self.call("POST", "/v1/login", {"username": "alice", "password": "wrong pass"})[0], 401)
        self.assertEqual(self.call("POST", "/v1/login", {"username": "nobody", "password": "wrong pass"})[0], 401)
        self.assertEqual(self.call("GET", "/v1/friends", token="bogus")[0], 401)
        self.assertEqual(self.call("GET", "/v1/friends")[0], 401)
        self.assertEqual(self.call("GET", "/v1/config")[1]["relay"], "relay.example:27970")

    def test_bad_bodies(self):
        self.assertEqual(self.call("POST", "/v1/login", raw=b"not json")[0], 400)
        self.assertEqual(self.call("POST", "/v1/login", raw=b"[1]")[0], 400)
        self.assertEqual(self.call("POST", "/v1/login", raw=b"x" * 5000)[0], 413)
        self.assertEqual(self.call("POST", "/v1/login", {"username": 5, "password": "x"})[0], 400)
        self.assertEqual(self.call("GET", "/v1/nothing")[0], 404)

    def test_friend_flow_presence_and_invites(self):
        a, b, c = self.account("alice"), self.account("bob"), self.account("carol")
        self.assertEqual(self.call("POST", "/v1/friends/request", {"username": "bob"}, a)[1]["result"], "requested")
        self.assertEqual(self.call("GET", "/v1/friends", token=b)[1]["incoming"], ["alice"])
        self.assertEqual(self.call("GET", "/v1/friends", token=a)[1]["outgoing"], ["bob"])
        self.assertEqual(self.call("POST", "/v1/friends/accept", {"username": "bob"}, a)[0], 404)  # wrong side
        self.assertEqual(self.call("POST", "/v1/friends/accept", {"username": "alice"}, b)[0], 200)
        fa = self.call("GET", "/v1/friends", token=a)[1]
        self.assertEqual([f["name"] for f in fa["friends"]], ["bob"])
        self.assertEqual(fa["friends"][0]["status"], "offline")

        # invites need a session and a friendship
        self.assertEqual(self.call("POST", "/v1/invite", {"username": "bob"}, a)[0], 409)
        self.assertEqual(self.call("POST", "/v1/presence", {"status": "playing", "session_code": "abc"}, a)[0], 400)
        self.assertEqual(self.call("POST", "/v1/presence", {"status": "playing", "session_code": "QEJAXY"}, a)[0], 200)
        self.assertEqual(self.call("GET", "/v1/friends", token=b)[1]["friends"][0]["status"], "playing")
        self.assertEqual(self.call("POST", "/v1/invite", {"username": "carol"}, a)[0], 404)
        self.assertEqual(self.call("POST", "/v1/invite", {"username": "bob"}, a)[0], 200)
        inv = self.call("GET", "/v1/invites", token=b)[1]["invites"]
        self.assertEqual([(i["from"], i["code"]) for i in inv], [("alice", "QEJAXY")])
        self.assertEqual(self.call("GET", "/v1/invites", token=c)[1]["invites"], [])
        self.call("POST", "/v1/invites/dismiss", {"id": inv[0]["id"]}, c)  # not carol's: no effect
        self.assertEqual(len(self.call("GET", "/v1/invites", token=b)[1]["invites"]), 1)
        self.call("POST", "/v1/invites/dismiss", {"id": inv[0]["id"]}, b)
        self.assertEqual(self.call("GET", "/v1/invites", token=b)[1]["invites"], [])

        # a session code is never shown in the friends list
        self.assertNotIn("QEJAXY", json.dumps(self.call("GET", "/v1/friends", token=b)[1]))

        # going offline clears the session; unfriend removes everything
        self.call("POST", "/v1/presence", {"status": "offline"}, a)
        self.assertEqual(self.call("GET", "/v1/friends", token=b)[1]["friends"][0]["status"], "offline")
        self.call("POST", "/v1/friends/remove", {"username": "alice"}, b)
        self.assertEqual(self.call("GET", "/v1/friends", token=a)[1]["friends"], [])

    def test_mutual_requests_become_friends(self):
        a, b = self.account("alice"), self.account("bob")
        self.call("POST", "/v1/friends/request", {"username": "bob"}, a)
        self.assertEqual(self.call("POST", "/v1/friends/request", {"username": "alice"}, b)[1]["result"], "friends")
        self.assertEqual(self.call("POST", "/v1/friends/request", {"username": "bob"}, a)[1]["result"], "already friends")
        self.assertEqual(self.call("POST", "/v1/friends/request", {"username": "alice"}, a)[1]["error"], "That's you.")

    def test_password_change_and_delete(self):
        a = self.account("alice")
        st, r = self.call("POST", "/v1/password", {"old_password": "correct horse", "new_password": "battery staple"}, a)
        self.assertEqual(st, 200)
        self.assertEqual(self.call("GET", "/v1/friends", token=a)[0], 401)  # old token signed out
        new = r["token"]
        self.assertEqual(self.call("GET", "/v1/friends", token=new)[0], 200)
        self.assertEqual(self.call("POST", "/v1/delete-account", {"password": "nope nope"}, new)[0], 401)
        self.assertEqual(self.call("POST", "/v1/delete-account", {"password": "battery staple"}, new)[0], 200)
        self.assertEqual(self.call("GET", "/v1/friends", token=new)[0], 401)
        self.account("alice")  # name is free again

    def test_login_rate_limit(self):
        self.account("alice")
        codes = [self.call("POST", "/v1/login", {"username": "alice", "password": "wrong pass"})[0]
                 for _ in range(F.AUTH_BURST + 2)]
        self.assertEqual(codes[:F.AUTH_BURST], [401] * F.AUTH_BURST)
        self.assertEqual(codes[F.AUTH_BURST:], [429, 429])


if __name__ == "__main__":
    unittest.main()
