#!/usr/bin/env python3
"""Fable II co-op relay (f37).

Runs on the home server. Games never talk to each other directly: each game
sends to the relay, and the relay passes packets on to the other players in
the same session. Players never learn each other's IP addresses.

What the relay does:
  * sessions with invite codes (CREATE -> new code, JOIN code -> join),
    at most 4 players each;
  * checks every packet's shape (magic, version, type, exact length, the
    sender id the player registered with) and the values in STATE packets,
    and drops anything else;
  * per-player rate limits and per-address limits on join attempts (so codes
    can't be guessed by brute force);
  * forgets silent players after 10 s and empty sessions straight away (a
    host that comes back within 60 s gets its old code back).

It does NOT run the game. Wire format: see src/net/mp_net.h.

Usage: python relay.py [--port 27970] [--bind 0.0.0.0]
"""
from __future__ import annotations

import argparse
import asyncio
import logging
import math
import secrets
import struct
import time
from dataclasses import dataclass, field

MAGIC = 0x504D3246  # "F2MP" little-endian
PROTO = 2              # newest game protocol (used in the relay's own replies)
PROTOS = (1, 2)        # accepted; a session only takes players with its host's version
HEADER = struct.Struct("<IBBHII")  # magic, proto, type, flags, sender, seq
assert HEADER.size == 16

# game messages (forwarded)
HELLO, STATE, POSE, BYE, POSEQ = 1, 2, 3, 4, 5
GAME_TYPES = {1: (HELLO, STATE, POSE), 2: (HELLO, STATE, POSE, BYE, POSEQ)}
# relay messages
CREATE, JOIN, WELCOME, REFUSED = 16, 17, 18, 19

REFUSE_BAD_CODE, REFUSE_FULL, REFUSE_SLOW_DOWN, REFUSE_NOT_JOINED, REFUSE_SERVER_FULL, REFUSE_VERSION = 1, 2, 3, 4, 5, 6
REFUSE_UNSUPPORTED = 7  # the game is newer than this relay (the game shows CO-105)

MAX_PLAYERS = 4
MAX_SESSIONS = 64
CODE_LEN = 6
CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O, 1/I
PLAYER_TIMEOUT = 10.0
CODE_HOLD = 60.0  # an emptied session's code is kept this long for its host

MAX_BONES = 256
BONES_PER_PACKET = 48
MAX_PARTS = 4
MAX_COORD = 100000.0

# per player: token buckets (packets/s, bytes/s); a normal player sends about
# 130 packets and 110 KB per second at 30 Hz
RATE_PACKETS = 400.0
RATE_BYTES = 400_000.0
# per address: join/create attempts
JOIN_BURST = 5
JOIN_PER_SEC = 0.5
REFUSE_NOTICE_GAP = 1.0  # at most one "not joined" reply per second per address

log = logging.getLogger("relay")


class Bucket:
    def __init__(self, rate: float, burst: float):
        self.rate, self.burst, self.level, self.t = rate, burst, burst, time.monotonic()

    def take(self, n: float, now: float) -> bool:
        self.level = min(self.burst, self.level + (now - self.t) * self.rate)
        self.t = now
        if self.level < n:
            return False
        self.level -= n
        return True


@dataclass
class Player:
    addr: tuple
    pid: int
    session: "Session"
    last_heard: float
    packets: Bucket = field(default_factory=lambda: Bucket(RATE_PACKETS, RATE_PACKETS))
    bytes: Bucket = field(default_factory=lambda: Bucket(RATE_BYTES, RATE_BYTES))
    dropped: int = 0


@dataclass
class Session:
    code: str
    host_pid: int
    created: float
    proto: int = PROTO
    players: dict = field(default_factory=dict)  # addr -> Player
    emptied: float | None = None


def check_game_packet(mtype: int, data: bytes) -> bool:
    """Shape and value checks for HELLO / STATE / POSE (header already parsed)."""
    n = len(data)
    if mtype == HELLO:
        if n != 20:
            return False
        bones, _ = struct.unpack_from("<HH", data, 16)
        return bones <= MAX_BONES
    if mtype == STATE:
        if n != 44:
            return False
        _t, x, y, z, qz, qw, _f = struct.unpack_from("<IfffffI", data, 16)
        for v in (x, y, z):
            if not math.isfinite(v) or abs(v) > MAX_COORD:
                return False
        if not (math.isfinite(qz) and math.isfinite(qw)):
            return False
        ln = math.hypot(qz, qw)
        return 0.5 <= ln <= 1.5
    if mtype == POSE:
        if n < 28:
            return False
        _frame, bones, first, count, part, parts = struct.unpack_from("<IHHHBB", data, 16)
        if not (0 < bones <= MAX_BONES and 0 < count <= BONES_PER_PACKET and first + count <= bones):
            return False
        if not (0 < parts <= MAX_PARTS and part < parts):
            return False
        return n == 28 + count * 24
    if mtype == POSEQ:
        if n < 32:
            return False
        _frame, bones, first, count, part, parts, layout = struct.unpack_from("<IHHHBBB", data, 16)
        if not (0 < bones <= MAX_BONES and 0 < count <= BONES_PER_PACKET and first + count <= bones):
            return False
        if not (0 < parts <= MAX_PARTS and part < parts and layout in (1, 2)):
            return False
        return n == 32 + count * 14
    if mtype == BYE:
        return n == 16
    return False


class Relay(asyncio.DatagramProtocol):
    def __init__(self):
        self.transport: asyncio.DatagramTransport | None = None
        self.sessions: dict[str, Session] = {}
        self.players: dict[tuple, Player] = {}
        self.join_limits: dict[str, Bucket] = {}
        self.refuse_notice: dict[tuple, float] = {}
        self.seq = 0
        self.stats = {"in": 0, "out": 0, "dropped": 0}

    # --- sending -------------------------------------------------------------
    def _relay_header(self, mtype: int, proto: int = PROTO) -> bytes:
        self.seq = (self.seq + 1) & 0xFFFFFFFF
        return HEADER.pack(MAGIC, proto, mtype, 0, 0, self.seq)

    def _send(self, data: bytes, addr):
        self.transport.sendto(data, addr)
        self.stats["out"] += 1

    def _welcome(self, p: Player):
        s = p.session
        body = struct.pack("<8sBBH", s.code.encode().ljust(8, b"\0"), len(s.players), MAX_PLAYERS,
                           1 if p.pid == s.host_pid else 0)
        self._send(self._relay_header(WELCOME, s.proto) + body, p.addr)

    def _refuse(self, addr, reason: int, proto: int = PROTO):
        self._send(self._relay_header(REFUSED, proto) + struct.pack("<BBH", reason, 0, 0), addr)

    # --- sessions ------------------------------------------------------------
    def _new_code(self) -> str | None:
        for _ in range(100):
            code = "".join(secrets.choice(CODE_ALPHABET) for _ in range(CODE_LEN))
            if code not in self.sessions:
                return code
        return None

    def _add_player(self, addr, pid: int, s: Session, now: float) -> Player:
        p = Player(addr=addr, pid=pid, session=s, last_heard=now)
        s.players[addr] = p
        s.emptied = None
        self.players[addr] = p
        log.info("player %08X joined %s (%d/%d)", pid, s.code, len(s.players), MAX_PLAYERS)
        return p

    def _remove_player(self, p: Player, now: float, why: str):
        s = p.session
        s.players.pop(p.addr, None)
        self.players.pop(p.addr, None)
        log.info("player %08X left %s (%s; %d left)", p.pid, s.code, why, len(s.players))
        if not s.players:
            s.emptied = now

    def _join_allowed(self, addr, now: float) -> bool:
        b = self.join_limits.get(addr[0])
        if b is None:
            b = self.join_limits[addr[0]] = Bucket(JOIN_PER_SEC, JOIN_BURST)
        return b.take(1, now)

    def _on_create(self, addr, pid: int, body: bytes, now: float, proto: int = PROTO):
        if len(body) != 8:
            return self._drop()
        p = self.players.get(addr)
        if p and p.pid == pid:
            return self._welcome(p)  # repeat of a CREATE we already answered
        if not self._join_allowed(addr, now):
            return self._refuse(addr, REFUSE_SLOW_DOWN, proto)
        if p:
            self._remove_player(p, now, "re-created")
        want = body.rstrip(b"\0").decode("ascii", "replace")
        s = self.sessions.get(want) if want else None
        if s and s.host_pid == pid and not s.players:
            s.proto = proto  # host coming back to its held code
        else:
            if len(self.sessions) >= MAX_SESSIONS:
                return self._refuse(addr, REFUSE_SERVER_FULL, proto)
            code = want if (want and want not in self.sessions and len(want) == CODE_LEN
                            and all(c in CODE_ALPHABET for c in want)) else self._new_code()
            if code is None:
                return self._refuse(addr, REFUSE_SERVER_FULL, proto)
            s = self.sessions[code] = Session(code=code, host_pid=pid, created=now, proto=proto)
            log.info("session %s created by %08X", code, pid)
        self._welcome(self._add_player(addr, pid, s, now))

    def _on_join(self, addr, pid: int, body: bytes, now: float, proto: int = PROTO):
        if len(body) != 8:
            return self._drop()
        p = self.players.get(addr)
        code = body.rstrip(b"\0").decode("ascii", "replace").upper()
        if p and p.pid == pid and p.session.code == code:
            return self._welcome(p)
        if not self._join_allowed(addr, now):
            return self._refuse(addr, REFUSE_SLOW_DOWN, proto)
        s = self.sessions.get(code)
        if s is None or (not s.players and s.emptied is not None):
            return self._refuse(addr, REFUSE_BAD_CODE, proto)
        if s.proto != proto:
            return self._refuse(addr, REFUSE_VERSION, proto)
        if any(q.pid == pid for q in s.players.values()):
            return self._refuse(addr, REFUSE_BAD_CODE, proto)  # id clash: client picks a new one
        if len(s.players) >= MAX_PLAYERS:
            return self._refuse(addr, REFUSE_FULL, proto)
        if p:
            self._remove_player(p, now, "joined another session")
        self._welcome(self._add_player(addr, pid, s, now))

    # --- receiving -----------------------------------------------------------
    def _drop(self):
        self.stats["dropped"] += 1

    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data: bytes, addr):
        self.stats["in"] += 1
        now = time.monotonic()
        if len(data) < 16 or len(data) > 1500:
            return self._drop()
        magic, proto, mtype, _flags, sender, _seq = HEADER.unpack_from(data)
        if magic != MAGIC or sender == 0:
            return self._drop()
        if proto not in PROTOS:
            # A newer game asking to get in: tell it (in its own protocol version,
            # which it can parse) rather than letting it wait for an answer.
            quiet = now - self.refuse_notice.get(addr, 0.0) < REFUSE_NOTICE_GAP
            if mtype in (CREATE, JOIN) and len(data) == 24 and not quiet:
                self.refuse_notice[addr] = now
                self._refuse(addr, REFUSE_UNSUPPORTED, proto)
            return self._drop()
        if mtype == CREATE:
            return self._on_create(addr, sender, data[16:], now, proto)
        if mtype == JOIN:
            return self._on_join(addr, sender, data[16:], now, proto)
        if mtype not in GAME_TYPES[proto]:
            return self._drop()
        p = self.players.get(addr)
        if p is None or p.pid != sender or p.session.proto != proto:
            self._drop()
            # tell the game it is not in a session any more (e.g. relay restarted)
            if mtype != BYE and now - self.refuse_notice.get(addr, 0.0) >= REFUSE_NOTICE_GAP:
                self.refuse_notice[addr] = now
                self._refuse(addr, REFUSE_NOT_JOINED, proto)
            return
        if not (p.packets.take(1, now) and p.bytes.take(len(data), now)):
            p.dropped += 1
            return self._drop()
        if not check_game_packet(mtype, data):
            p.dropped += 1
            return self._drop()
        p.last_heard = now
        for q in p.session.players.values():
            if q is not p:
                self._send(data, q.addr)
        if mtype == BYE:
            self._remove_player(p, now, "left")

    # --- housekeeping --------------------------------------------------------
    def sweep(self):
        now = time.monotonic()
        for p in list(self.players.values()):
            if now - p.last_heard > PLAYER_TIMEOUT:
                self._remove_player(p, now, "timed out")
        for code, s in list(self.sessions.items()):
            if not s.players and s.emptied is not None and now - s.emptied > CODE_HOLD:
                del self.sessions[code]
                log.info("session %s closed", code)
        for ip, b in list(self.join_limits.items()):
            b.take(0, now)
            if b.level >= b.burst:
                del self.join_limits[ip]
        for a, t in list(self.refuse_notice.items()):
            if now - t > 10:
                del self.refuse_notice[a]


async def main_async(bind: str, port: int):
    loop = asyncio.get_running_loop()
    transport, relay = await loop.create_datagram_endpoint(Relay, local_addr=(bind, port))
    log.info("relay listening on UDP %s:%d", bind, port)
    last_stats = time.monotonic()
    try:
        while True:
            await asyncio.sleep(1.0)
            relay.sweep()
            if time.monotonic() - last_stats >= 60:
                last_stats = time.monotonic()
                live = sum(1 for s in relay.sessions.values() if s.players)
                log.info("stats: %d session(s) live, %d player(s); packets in %d out %d dropped %d",
                         live, len(relay.players), relay.stats["in"], relay.stats["out"],
                         relay.stats["dropped"])
    finally:
        transport.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--port", type=int, default=27970)
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    try:
        asyncio.run(main_async(args.bind, args.port))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
