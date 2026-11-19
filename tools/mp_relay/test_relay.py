"""Tests for relay.py over real UDP on localhost: python -m unittest test_relay (from this folder)."""
import asyncio
import socket
import struct
import unittest

import relay as R


def hdr(mtype, sender, seq=1, proto=R.PROTO):
    return R.HEADER.pack(R.MAGIC, proto, mtype, 0, sender, seq)


def hello(sender, bones=143):
    return hdr(R.HELLO, sender) + struct.pack("<HH", bones, 0)


def state(sender, x=1.0, qz=0.0, qw=1.0):
    return hdr(R.STATE, sender) + struct.pack("<IfffffI", 5, x, 2.0, 3.0, qz, qw, 7)


def pose(sender, count=48, first=0, bones=143, part=0, parts=1):
    return (hdr(R.POSE, sender) + struct.pack("<IHHHBB", 9, bones, first, count, part, parts)
            + b"\0" * (count * 24))


def poseq(sender, count=48, first=0, bones=143, part=0, parts=1, layout=1):
    return (hdr(R.POSEQ, sender) + struct.pack("<IHHHBBBBH", 9, bones, first, count, part, parts, layout, 0, 0)
            + b"\0" * (count * 14))


def create(sender, want="", proto=R.PROTO):
    return hdr(R.CREATE, sender, proto=proto) + want.encode().ljust(8, b"\0")


def join(sender, code, proto=R.PROTO):
    return hdr(R.JOIN, sender, proto=proto) + code.encode().ljust(8, b"\0")


class Client:
    def __init__(self, port):
        self.s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.s.bind(("127.0.0.1", 0))
        self.s.setblocking(False)
        self.dst = ("127.0.0.1", port)

    def send(self, data):
        self.s.sendto(data, self.dst)

    def recv_all(self):
        out = []
        while True:
            try:
                out.append(self.s.recv(2048))
            except BlockingIOError:
                return out

    def close(self):
        self.s.close()


def parse(pkts):
    res = []
    for d in pkts:
        _m, _p, t, _f, sender, _s = R.HEADER.unpack_from(d)
        res.append((t, sender, d))
    return res


class RelayTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        loop = asyncio.get_running_loop()
        self.transport, self.relay = await loop.create_datagram_endpoint(
            R.Relay, local_addr=("127.0.0.1", 0))
        self.port = self.transport.get_extra_info("sockname")[1]
        self.clients = []

    async def asyncTearDown(self):
        for c in self.clients:
            c.close()
        self.transport.close()

    def client(self):
        c = Client(self.port)
        self.clients.append(c)
        return c

    async def pump(self):
        await asyncio.sleep(0.05)

    async def host_session(self, c, pid):
        c.send(create(pid))
        await self.pump()
        got = parse(c.recv_all())
        self.assertEqual(got[0][0], R.WELCOME)
        code = got[0][2][16:24].rstrip(b"\0").decode()
        self.assertEqual(len(code), R.CODE_LEN)
        return code

    async def test_create_join_forward(self):
        a, b = self.client(), self.client()
        code = await self.host_session(a, 11)
        b.send(join(13, code.lower()))  # codes are case-insensitive
        await self.pump()
        got = parse(b.recv_all())
        self.assertEqual(got[0][0], R.WELCOME)
        self.assertEqual(got[0][2][24], 2)  # players
        a.send(hello(11))
        a.send(state(11))
        a.send(pose(11))
        await self.pump()
        types = [t for t, s, _ in parse(b.recv_all())]
        self.assertEqual(types, [R.HELLO, R.STATE, R.POSE])
        self.assertEqual(a.recv_all(), [])  # never echoed to the sender

    async def test_bad_packets_dropped(self):
        a, b = self.client(), self.client()
        code = await self.host_session(a, 11)
        b.send(join(13, code))
        await self.pump()
        b.recv_all()
        bad = [
            state(11, x=float("nan")),
            state(11, x=1e9),
            state(11, qz=0.0, qw=0.1),
            pose(11, count=49),
            pose(11, first=140, count=10),
            pose(11, part=1, parts=1),
            pose(11)[:-1],
            hello(11, bones=999),
            hdr(99, 11),
            state(12),  # wrong sender id for this address
        ]
        for d in bad:
            a.send(d)
        await self.pump()
        self.assertEqual(b.recv_all(), [])

    async def test_unjoined_gets_refused_not_forwarded(self):
        a, b = self.client(), self.client()
        code = await self.host_session(a, 11)
        b.send(state(13))
        await self.pump()
        got = parse(b.recv_all())
        self.assertEqual([t for t, *_ in got], [R.REFUSED])
        self.assertEqual(got[0][2][16], R.REFUSE_NOT_JOINED)
        self.assertEqual(a.recv_all(), [])

    async def test_wrong_code_and_rate_limit(self):
        a, b = self.client(), self.client()
        await self.host_session(a, 11)
        reasons = []
        for _ in range(8):
            b.send(join(13, "ZZZZZZ"))
        await self.pump()
        for t, _s, d in parse(b.recv_all()):
            self.assertEqual(t, R.REFUSED)
            reasons.append(d[16])
        # the host's CREATE used one of this address's tokens (same IP on localhost)
        bad = R.JOIN_BURST - 1
        self.assertEqual(reasons, [R.REFUSE_BAD_CODE] * bad + [R.REFUSE_SLOW_DOWN] * (8 - bad))

    async def test_full_session(self):
        host = self.client()
        code = await self.host_session(host, 1)
        for i in range(R.MAX_PLAYERS - 1):
            c = self.client()
            c.send(join(100 + i, code))
            await self.pump()
            self.assertEqual(parse(c.recv_all())[0][0], R.WELCOME)
        extra = self.client()
        extra.send(join(999, code))
        await self.pump()
        got = parse(extra.recv_all())
        self.assertEqual(got[0][0], R.REFUSED)
        self.assertEqual(got[0][2][16], R.REFUSE_FULL)

    async def test_host_reclaims_code_after_relay_forgets(self):
        a = self.client()
        code = await self.host_session(a, 11)
        p = self.relay.players[next(iter(self.relay.players))]
        self.relay._remove_player(p, 0.0, "test")
        a.send(create(11, code))
        await self.pump()
        got = parse(a.recv_all())
        self.assertEqual(got[0][0], R.WELCOME)
        self.assertEqual(got[0][2][16:24].rstrip(b"\0").decode(), code)

    async def test_repeated_create_is_idempotent(self):
        a = self.client()
        code = await self.host_session(a, 11)
        a.send(create(11))
        await self.pump()
        got = parse(a.recv_all())
        self.assertEqual(got[0][2][16:24].rstrip(b"\0").decode(), code)
        self.assertEqual(len(self.relay.sessions), 1)


class RelayV2Test(RelayTest):
    async def test_poseq_and_bye(self):
        a, b = self.client(), self.client()
        code = await self.host_session(a, 11)
        b.send(join(13, code))
        await self.pump()
        b.recv_all()
        a.send(poseq(11))
        a.send(poseq(11, layout=3))  # bad layout
        a.send(poseq(11)[:-2])       # bad length
        await self.pump()
        self.assertEqual([t for t, *_ in parse(b.recv_all())], [R.POSEQ])
        a.send(hdr(R.BYE, 11))
        await self.pump()
        self.assertEqual([t for t, *_ in parse(b.recv_all())], [R.BYE])
        self.assertNotIn(a.s.getsockname(), self.relay.players)  # BYE leaves at once
        self.assertEqual(len(next(iter(self.relay.sessions.values())).players), 1)

    async def test_hit_only_to_target(self):
        a, b, c = self.client(), self.client(), self.client()
        code = await self.host_session(a, 11)
        for cl, pid in ((b, 13), (c, 15)):
            cl.send(join(pid, code))
        await self.pump()
        b.recv_all(), c.recv_all()

        def hit(target, dmg):
            return hdr(R.HIT, 11) + struct.pack("<IfI", target, dmg, 0)
        a.send(hit(13, 7.5))
        a.send(hit(13, 0.0))            # no damage
        a.send(hit(13, 501.0))          # too much
        a.send(hit(13, float("nan")))
        a.send(hit(0, 5.0))             # no target
        a.send(hit(13, 7.5)[:-4])       # bad length
        await self.pump()
        got = parse(b.recv_all())
        self.assertEqual([t for t, *_ in got], [R.HIT])
        self.assertEqual(c.recv_all(), [])  # not for the third player
        # an older (proto 2) session cannot carry HIT
        d, e = self.client(), self.client()
        d.send(create(21, proto=2))
        await self.pump()
        code2 = parse(d.recv_all())[0][2][16:24].rstrip(b"\0").decode()
        e.send(join(23, code2, proto=2))
        await self.pump()
        e.recv_all()
        d.send(hdr(R.HIT, 21, proto=2) + struct.pack("<IfI", 23, 5.0, 0))
        await self.pump()
        self.assertEqual(e.recv_all(), [])

    async def test_enemies_checked_and_forwarded(self):
        a, b = self.client(), self.client()
        code = await self.host_session(a, 11)
        b.send(join(13, code))
        await self.pump()
        b.recv_all()

        def enemies(*ents, count=None):
            body = b"".join(R.ENEMY.pack(*e) for e in ents)
            n = len(ents) if count is None else count
            return hdr(R.ENEMIES, 11) + struct.pack("<BBH", n, 0, 0) + body
        good = (1, 0, 0, 0x6E5F42EF, 1.0, 2.0, 3.0, 0.0, 1.0, 900.0)
        a.send(enemies())                                   # none near: fine
        a.send(enemies(good, good))
        a.send(enemies(good, count=2))                      # count/length mismatch
        a.send(enemies((1, 0, 0, 0, 1.0, 2.0, 3.0, 0.0, 1.0, 9.0)))   # no record
        a.send(enemies((1, 0, 0, 5, float("inf"), 2.0, 3.0, 0.0, 1.0, 9.0)))
        a.send(enemies((1, 0, 0, 5, 1.0, 2.0, 3.0, 0.0, 0.0, 9.0)))   # bad facing
        a.send(enemies(*([good] * 25)))                     # too many
        await self.pump()
        self.assertEqual([t for t, *_ in parse(b.recv_all())], [R.ENEMIES, R.ENEMIES])

    async def test_version_mismatch_refused(self):
        a, b = self.client(), self.client()
        a.send(create(11, proto=1))
        await self.pump()
        code = parse(a.recv_all())[0][2][16:24].rstrip(b"\0").decode()
        b.send(join(13, code, proto=2))
        await self.pump()
        got = parse(b.recv_all())
        self.assertEqual((got[0][0], got[0][2][16]), (R.REFUSED, R.REFUSE_VERSION))
        # an old (proto 1) game cannot send new message types
        b2 = self.client()
        b2.send(join(14, code, proto=1))
        await self.pump()
        self.assertEqual(parse(b2.recv_all())[0][0], R.WELCOME)
        a.send(hdr(R.BYE, 11, proto=1))
        a.send(hdr(R.STATE, 11, proto=1) + struct.pack("<IfffffI", 5, 1.0, 2.0, 3.0, 0.0, 1.0, 7))
        await self.pump()
        self.assertEqual([t for t, *_ in parse(b2.recv_all())], [R.STATE])

    async def test_newer_game_told_unsupported(self):
        a = self.client()
        a.send(create(11, proto=R.PROTO + 1))
        a.send(create(11, proto=R.PROTO + 1))  # second one inside the notice gap: silent
        await self.pump()
        got = a.recv_all()
        self.assertEqual(len(got), 1)
        _m, proto, t, _f, _s, _q = R.HEADER.unpack_from(got[0])
        self.assertEqual((proto, t, got[0][16]), (R.PROTO + 1, R.REFUSED, R.REFUSE_UNSUPPORTED))
        self.assertEqual(len(self.relay.sessions), 0)


if __name__ == "__main__":
    unittest.main()
