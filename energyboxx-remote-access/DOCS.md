# Energyboxx Remote Access — Documentation

Requires Home Assistant 2024.11.0 or newer on a 64-bit system (`aarch64` or `amd64`).

## Options

| Option | Required | Description |
|---|---|---|
| `access_code` | yes | The code from your home's "Remote access" page on the Energyboxx platform. |
| `log_level` | no | `debug`, `info` (default), `warning` or `error`. Hidden under "Show unused optional configuration options". |

## What it does

While the add-on runs, it keeps one outgoing, encrypted connection open to the Energyboxx tunnel server (`tunnel.grexxconnect.com`). Through that connection Energyboxx support can open the Home Assistant web interface from the Energyboxx office network.

- **Nothing is opened on your router** and Home Assistant is not reachable from the internet.
- **Only the Home Assistant web interface** is forwarded. The add-on cannot reach other devices on your network.
- **A Home Assistant login is still required.** Create a separate user for Energyboxx support (Settings → People → Add person) so you can see what it does and remove it at any time. If it does not need to change settings, leave "Administrator" off.
- **Home Assistant sees support as a local connection.** Requests arrive from the add-on's address inside your Home Assistant system, so users marked "Can only log in from the local network" can also log in through remote access. Give those users strong passwords too.
- **Login without a password is refused.** If Home Assistant's `trusted_networks` auth provider covers the add-on's network, anyone using remote access would be logged in without a password. The add-on checks this at start and every 5 minutes, and stops with a notification if it finds it. It also refuses to start before Home Assistant onboarding is finished.
- **You stay in control.** The add-on does not start on boot unless you turn that on. Stop it, or remove the access code on the platform, and remote access ends within a minute.

Energyboxx operates the tunnel server, so the traffic is decrypted there before it is passed to your Home Assistant. Only use this add-on if you trust Energyboxx with access to your Home Assistant.

## Troubleshooting

Problems show up as a notification in Home Assistant (the bell in the sidebar).

- **"cannot start: no access code is set" / "not valid" / "incomplete"** — copy the code again from the Energyboxx platform; it is one long line of letters and digits.
- **"the Energyboxx tunnel rejected the access code"** — the code was regenerated or revoked. Generate a new one on the platform.
- **"cannot connect to the Energyboxx tunnel"** — your internet connection or the tunnel server is down. The add-on keeps retrying and clears the notification once connected.
- **"lets this add-on's network log in without a password"** — remove the Home Assistant network (`172.30.32.0/23`, or a wider range such as `172.16.0.0/12`) from `trusted_networks` in `configuration.yaml` and restart Home Assistant.
- **Support sees "Login attempt failed" and is locked out** — if you enabled `ip_ban_enabled` in Home Assistant's `http` configuration, failed logins ban the add-on's address. Remove its entry from `ip_bans.yaml` and restart Home Assistant.

## For platform developers: access code format

The code is URL-safe base64 (padding optional) of a JSON object:

```json
{"v": 1, "home": "<home id>", "secret": "<secret>",
 "server": "tunnel.grexxconnect.com", "port": 7000}
```

| Field | Required | Notes |
|---|---|---|
| `v` | yes | Format version, must be `1`. |
| `home` | yes | Lower-case DNS label (`a-z`, `0-9`, `-`, max 63). The UI is served at `https://<home>.ha.grexxconnect.com`. Use a random id, not a guessable one. |
| `secret` | yes | At least 16 characters of `A-Z a-z 0-9 _ -`; use 128 bits or more of randomness. The tunnel server stores its sha256 (k8s repo, `auto/ha-tunnel`). |
| `server`, `port` | no | Default `tunnel.grexxconnect.com:7000`. The server certificate must be publicly trusted. |

Generate a test code:

```bash
python3 -c 'import base64,json,secrets;print(base64.urlsafe_b64encode(json.dumps({"v":1,"home":"test1","secret":secrets.token_urlsafe(24)}).encode()).decode().rstrip("="))'
```

## How it works

1. Reads the access code and writes the frp client configuration.
2. Checks Home Assistant's login providers (see above), then starts nginx on `127.0.0.1:8099`. nginx forwards to Home Assistant using the port and HTTP/HTTPS setting from the Supervisor, and removes `X-Forwarded-*` headers. Otherwise Home Assistant refuses requests that come through a proxy.
3. Starts `frpc`, which logs in to the tunnel server with the home's secret over TLS, verifying the server certificate, and registers the home's subdomain. It sends a heartbeat every 30 seconds, and the server re-checks the secret on each one.
