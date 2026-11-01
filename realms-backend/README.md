# SurrounSync Realms backend

A small Cloudflare Worker that keeps each Realm's newest world between sessions and decides who hosts.
- **D1** (database): Realms, members, invites, the host lease, the generation list.
- **R2** (storage): the world files (`realms/<id>/world/<gen>`). Characters stay on each player's PC.

Players never touch this. Their SurrounSync bridge talks to it.

## One-time setup (about 10 minutes)

1. Create a free account at https://dash.cloudflare.com/sign-up. Use it only for SurrounSync.
2. In the dashboard, open **R2** and click **Enable R2**. It may ask for a payment method even on the free plan.
   The free amount should be far more than Realms need. Check the current limits at https://developers.cloudflare.com/r2/pricing/.
3. In this folder:
   ```
   npm install
   npx wrangler login
   npx wrangler d1 create surrounsync-realms
   ```
   Copy the `database_id` it prints into `wrangler.toml` (it replaces the zeros).
4. Make the storage bucket and the tables, then publish:
   ```
   npx wrangler r2 bucket create surrounsync-realms
   npm run db:remote
   npm run deploy
   ```
   `deploy` prints the address, for example `https://surrounsync-realms.<you>.workers.dev`. The mod's bridge
   needs that address; nothing else is secret.
5. Check it: open `https://surrounsync-realms.<you>.workers.dev/v1` in a browser. It shows
   `{"service":"surrounsync-realms",...}`.

## Local test

```
rm -rf .wrangler/test-state && npm run db:local
npx wrangler dev --local --port 8787 --persist-to .wrangler/test-state --var LEASE_SECONDS:3
python -I test/test_api.py           # in a second terminal
```

## API (all under /v1; JSON unless noted)

Auth header for member calls: `Authorization: Member <member_id>:<key>`.

| Call | Who | What |
|---|---|---|
| `POST /realms` | anyone (5/day/IP) | create; returns code, owner member id + key |
| `GET /realms/<code>` | member | name, newest generation, who is hosting, members |
| `PATCH` / `DELETE /realms/<code>` | owner | rename / delete everything |
| `PUT /realms/<code>/rules` | owner | the game rules every host plays by (`{"rules": "pvp off players 4 ..."}`); `GET` and the heartbeat return them |
| `POST /realms/<code>/lease` | member | claim the host lease. 200 = you host; 409 = someone does (their SteamID) |
| `POST .../lease/heartbeat`, `DELETE .../lease` | host (`X-Lease-Token`) | keep (every ~60 s; it expires after 120 s) / release |
| `PUT .../world/<gen>` | host (`X-Lease-Token`, `X-Sha256`) | upload generation head+1 (binary, ≤16 MB); the last 10 are kept |
| `GET .../world`, `GET .../world/<gen>`, `GET .../generations` | member | download newest / a kept one / list |
| `POST .../invites` | member | one-time invite code, valid 7 days |
| `POST /invites/redeem` | invitee (20/h/IP) | invite → member id + key |
| `POST .../key` | member | new key (the old one stops working) |
| `DELETE .../members/<id>`, `POST .../members/<id>/owner` | owner (or yourself to leave) | remove / hand over ownership |
| `GET /motd` | anyone | the message of the day (`{"id": null}` when none); every bridge asks every minute (0.14.2 and older: every 10 min) |
| `PUT` / `DELETE /motd` | admin (`Authorization: Admin <token>`, 30/h/IP) | set (`{"text": "...", "hours": 48}` or `"minutes": 30`, 1-500 characters, the expiry optional, not both) / clear. Only exists once the `MOTD_TOKEN` secret is set; `tools/motd.ps1` does all of it |

Message of the day, once: `tools\motd.ps1 -Setup` (makes `tools\motd-token.txt`, not in git), then
`tools\MOTD-setup-server.cmd` (the motd table, that token as the `MOTD_TOKEN` secret, `npx wrangler deploy`).
All of it in a window (current message, send with an expiry, clear, Make token, Set up server): double-click `tools\MOTD.cmd`.

Keys and invite codes are random; only their sha256 is stored. Steam IDs are as the client claims them
(display and connection only, not proof of identity).
