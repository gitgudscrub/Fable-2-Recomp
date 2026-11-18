# Co-op friends service

Accounts, friends lists, online status and co-op invites for the launcher's
Co-op page. It runs on the home server next to the relay (`tools/mp_relay`) and
is reached over HTTPS through the Cloudflare tunnel. It uses only the Python
standard library, and everything is stored in one SQLite file.

- **Accounts:** a username and password. Passwords are stored as scrypt
  hashes. Signing in returns a token that lasts 90 days; the server keeps only
  a SHA-256 of it. Players can change their password, which signs them out
  everywhere, and can delete their account.
- **Friends:** send a request by username; the other player accepts it. If two
  players ask each other, they become friends straight away.
- **Presence:** the launcher reports every 30 s whether its player is online or
  in a co-op game. Only friends see it. The session code itself is never shown;
  it only travels inside an invite.
- **Invites:** a player in a co-op game invites a friend. The friend's launcher
  shows the invite and joins with one click. Invites expire after 10 minutes.
- **Limits:**
  - sign-up and sign-in attempts per address, using Cloudflare's
    `CF-Connecting-IP` header;
  - request size;
  - up to 200 friends and 50 open requests per player.
- **Relay address:** `GET /v1/config` hands it out, so players never type it.

## Run it

```sh
docker build -t fable2-friends tools/mp_friends
docker run -d --name fable2-friends --restart unless-stopped \
  -p 127.0.0.1:18090:18090 -v fable2-friends:/data \
  -e RELAY=<public relay host>:27970 fable2-friends
```

Then route a hostname in the Cloudflare tunnel to `http://localhost:18090`.
Only publish it through the tunnel, never directly: rate limits trust
Cloudflare's address header.

## Releases

The launcher finds the service through `coop.json` next to its exe. That file
is added when a release is packaged, from the release PC's
`%USERPROFILE%\.project-sparrow\coop.json`:

```json
{ "friends": "https://<your hostname>" }
```

If the file is missing, the release ships with friends turned off and the
manual Host / Join still works. To test against a local service, set
`PROJECT_SPARROW_FRIENDS=http://127.0.0.1:18090`.

## Tests

```sh
cd tools/mp_friends && python -m unittest test_friends
```
