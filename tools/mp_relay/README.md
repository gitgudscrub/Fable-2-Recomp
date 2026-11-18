# Co-op relay

A small UDP relay for Fable II co-op (up to 4 players). It runs on a home
server. Games never connect to each other directly: each game talks only to
the relay, and the relay passes its packets on to the other players in the same
session. Players never see each other's IP addresses.

The relay does not run the game. It only:

- creates sessions and hands out invite codes, with at most 4 players per session;
- checks every packet (format, version, length, sender, value ranges) and drops
  bad ones;
- limits how many packets and bytes each player can send, and how often one
  address can try invite codes;
- forgets silent players after 10 s. If the relay restarts, the host gets the
  same code back and the other players rejoin automatically.

The message format is described at the top of `src/net/mp_net.h`.

## Run it

```sh
docker build -t fable2-relay tools/mp_relay
docker run -d --name fable2-relay --restart unless-stopped -p 27970:27970/udp fable2-relay
docker logs -f fable2-relay
```

Or, without Docker: `python tools/mp_relay/relay.py --port 27970` (Python 3.10+, no other packages).

Players outside your home network need a router rule that forwards UDP 27970
to the server. Docker publishes the port itself, so you do not need a ufw rule
for the container.

## Play

Host:

```
fable_2.exe --mp_enable=true --mp_relay=<server>:27970 --mp_host=true
```

The invite code shows up in the log (`[mpnet] in session ABC123`) and in
`mp_session.txt` next to the exe.

Friends:

```
fable_2.exe --mp_enable=true --mp_relay=<server>:27970 --mp_join=ABC123
```

## Tests

```sh
cd tools/mp_relay && python -m unittest test_relay
```
