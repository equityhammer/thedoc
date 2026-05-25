[← Android Manifesto index](./ANDROID_MANIFESTO.md)

# Local-server port registry

Every app's `dist/serve_<app>.py` binds a unique port on the Tailscale net
(`100.107.198.124`). Claim a port here **before** standing up a new server so two
apps never collide. Ports below are re-derived from each server's actual source
(not from memory) as of 2026-05-24.

| Port | Project | Server / role | How it's set |
|------|---------|---------------|--------------|
| `8723`  | command-line-voice | voice/TTS server | (documented in ecosystem comments) |
| `8888`  | no-more-time-blindness-android (NMTB) | sideload server | env `NMTB_PORT`, default `8888` |
| `8889`  | claude-relay | sideload server | env `RELAY_SIDELOAD_PORT`, default `8889` |
| `18091` | android-transfer-checklist | sideload server | hardcoded `PORT = 18091` |
| `18789` | OpenClaw | gateway (`ws://127.0.0.1:18789`) | OpenClaw config |
| `41100` | android-notification-relay | sideload server | env `NOTIFRELAY_PORT`, default `41100` |

## Unassigned / TODO

- **hymn-recognizer** — no `dist/` server yet. When wiring the sprint loop, claim a
  free port here first (e.g. next in the `41101+` range to stay clear of the cluster
  above).

## Rules

- One port per server role. `claude-relay` historically also referenced a relay
  control port (`8765`); if you revive a second server for an app, give it its own
  row.
- Prefer an env-var override with a sane default (`env <APP>_PORT`) over a hardcoded
  constant, so the same machine can run two instances if needed.
- Avoid the OpenClaw gateway port `18789` and anything already listed above.
