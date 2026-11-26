# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Home Assistant add-on repository (GitHub: `grexxlowcode/grexx-homeassistant-addons`). It contains one add-on, **Energyboxx Flow Params** (slug `energyboxx`), which subscribes to the Energyboxx community MQTT topics on `ess.grexxconnect.com:8883` and turns every subtopic into a `sensor.community_*` entity in Home Assistant, plus an "Energyboxx Flow Params" dashboard.

The add-on only reads. It never publishes to the broker.

## Repository Structure

- `energyboxx-flow-params/` — the add-on. The directory name is free; HA identifies the add-on by `slug` in `config.yaml`. **Never change the slug**: existing installs would lose their options and stop receiving updates.
  - `config.yaml` — options schema, version, architectures (`aarch64`, `amd64`)
  - `build.yaml` — base images (`ghcr.io/home-assistant/<arch>-base:3.22`)
  - `Dockerfile` — installs `jq mosquitto-clients curl python3 py3-websocket-client`
  - `run.sh` — entrypoint: installs CA, waits for HA API, checks credentials, builds the dashboard, then `exec`s the listener
  - `mqtt_helper_listener.sh` — `mosquitto_sub` loop that writes sensors via `POST /api/states`
  - `notify.sh` — sourced helpers to create/dismiss the HA persistent notification `energyboxx_flow_params`
  - `create_dashboard.py` — creates/overwrites the Lovelace dashboard over the HA WebSocket API
  - `dashboard.json` — dashboard layout with tokens `RESULT_SIGN_HINT` and `ADDON_UPDATE_ENTITY`
  - `ca.crt` — CA for the broker's TLS certificate
  - `translations/en.yaml`, `translations/nl.yaml` — option labels; keep both in sync
  - `DOCS.md`, `README.md`, `CHANGELOG.md` — user-facing; update with every change and bump `version` in `config.yaml`

## Runtime Flow

1. `run.sh` waits for `http://supervisor/core/api/` (up to 10 × 10s), then exits with a notification if username or password is empty.
2. `create_dashboard.py` looks up the add-on's update entity in the entity registry (unique id `<full slug>_version_latest`, platform `hassio`) because its entity id depends on the add-on name at install time. Dashboard failures never stop ingest.
3. `mqtt_helper_listener.sh`:
   - Runs `mosquitto_sub` against the broker in an endless loop with a 30s reconnect delay.
   - Lines starting with `Error`, `Connection error` or `Unable to connect` are broker errors: logged and shown as a notification. Any data message dismisses it.
   - Topic → entity: strip the `community_topic` prefix, lowercase, `/` → `_`, keep `[a-z0-9_]`, prefix `sensor.`.
   - `*_kw` gets unit `kW` + device class `power`; `*_price_eur` gets `€/kWh`; numeric values get `state_class: measurement`.
   - `flip_power_result_kw` (UI label "Show community export as positive") negates `sensor.community_power_result_kw`.
   - A background watcher probes the last written sensor every 60s; a 404 means HA core restarted and wiped the states, so it kills `mosquitto_sub` to reconnect and receive the broker's retained values again.

## Options

| Option | Notes |
|---|---|
| `energyboxx_mqtt_username` / `energyboxx_mqtt_password` | Required. |
| `community_topic` | Default `community/#`. |
| `flip_power_result_kw` | Default `true`. |
| `log_level` | Optional (`debug`, `info`, `warning`, `error`), applied with `bashio::log.level`. Per-message lines log at debug. |

Host and port are fixed in `run.sh`.

## Testing Changes

There is no automated test suite. Validate locally with:

```bash
bash -n energyboxx-flow-params/*.sh
python3 -m py_compile energyboxx-flow-params/create_dashboard.py
docker build --build-arg BUILD_FROM=ghcr.io/home-assistant/aarch64-base:3.22 energyboxx-flow-params
```

Then test in Home Assistant: the devcontainer (`.devcontainer/devcontainer.json`, task `supervisor_run`, UI on port 7123) mounts the repo as a local add-on. Rebuild and restart the add-on and check its Log tab.

## History

Versions before 1.1.0 also published HA states upstream (mosquitto bridge `topic # both`, `mqtt_statestream`, Tailscale via `headscale.grexx.io`). All of that was removed; see `CHANGELOG.md` and git history (last publishing version: `06cd5a6`).
