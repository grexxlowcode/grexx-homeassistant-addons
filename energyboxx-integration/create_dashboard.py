#!/usr/bin/env python3
"""Create or update the "Energyboxx Flow Params" Lovelace dashboard.

Lovelace dashboards are only reachable over the Home Assistant WebSocket API,
so this talks to the Supervisor's core WebSocket proxy using SUPERVISOR_TOKEN.
"""

import json
import os
import sys

from websocket import create_connection

WS_URL = "ws://supervisor/core/websocket"
CONFIG_FILE = "/app/dashboard.json"

URL_PATH = "energyboxx-flow-params"
TITLE = "Energyboxx Flow Params"
ICON = "mdi:transmission-tower"

TIMEOUT = 30

# The sign of sensor.community_power_result_kw depends on flip_power_result_kw,
# so the explanation in the dashboard is substituted at build time.
SIGN_HINT_TOKEN = "RESULT_SIGN_HINT"
SIGN_HINT_FLIPPED = (
    "positive means the community is exporting more than it imports, "
    "negative means it is importing more."
)
SIGN_HINT_RAW = (
    "positive means the community is importing more than it exports, "
    "negative means it is exporting more."
)


def log(message):
    print(message, flush=True)


def load_config():
    with open(CONFIG_FILE) as handle:
        raw = handle.read()

    flipped = os.environ.get("FLIP_POWER_RESULT_KW", "true").lower() == "true"
    hint = SIGN_HINT_FLIPPED if flipped else SIGN_HINT_RAW
    return json.loads(raw.replace(SIGN_HINT_TOKEN, hint))


class CommandFailed(Exception):
    pass


class Client:
    def __init__(self, ws):
        self.ws = ws
        self.last_id = 0

    def command(self, payload):
        self.last_id += 1
        message_id = self.last_id
        self.ws.send(json.dumps(dict(payload, id=message_id)))

        while True:
            message = json.loads(self.ws.recv())
            if message.get("id") != message_id or message.get("type") != "result":
                # Ignore events and results belonging to other commands.
                continue
            if not message.get("success"):
                error = message.get("error", {})
                raise CommandFailed(
                    "{0}: {1}".format(
                        error.get("code", "unknown"),
                        error.get("message", "no message"),
                    )
                )
            return message.get("result")


def authenticate(ws, token):
    greeting = json.loads(ws.recv())
    if greeting.get("type") != "auth_required":
        raise CommandFailed(
            "unexpected greeting from Home Assistant: {0}".format(greeting.get("type"))
        )

    ws.send(json.dumps({"type": "auth", "access_token": token}))
    reply = json.loads(ws.recv())
    if reply.get("type") != "auth_ok":
        raise CommandFailed(
            "authentication rejected: {0}".format(reply.get("message", reply.get("type")))
        )


def ensure_dashboard(client):
    dashboards = client.command({"type": "lovelace/dashboards/list"}) or []
    if any(dashboard.get("url_path") == URL_PATH for dashboard in dashboards):
        log("Dashboard '{0}' already exists.".format(URL_PATH))
        return

    client.command(
        {
            "type": "lovelace/dashboards/create",
            "url_path": URL_PATH,
            "title": TITLE,
            "icon": ICON,
            "show_in_sidebar": True,
            "require_admin": False,
        }
    )
    log("Created dashboard '{0}'.".format(URL_PATH))


def main():
    token = os.environ.get("SUPERVISOR_TOKEN")
    if not token:
        log("SUPERVISOR_TOKEN missing; cannot manage the dashboard.")
        return 1

    config = load_config()

    try:
        ws = create_connection(WS_URL, timeout=TIMEOUT)
    except Exception as err:  # noqa: BLE001 - any connection problem is non-fatal
        log("Could not connect to {0}: {1}".format(WS_URL, err))
        return 1

    try:
        authenticate(ws, token)
        client = Client(ws)
        ensure_dashboard(client)
        client.command(
            {
                "type": "lovelace/config/save",
                "url_path": URL_PATH,
                "config": config,
            }
        )
        log("Saved '{0}' configuration.".format(TITLE))
    except Exception as err:  # noqa: BLE001 - never block MQTT ingest
        log("Dashboard setup failed: {0}".format(err))
        return 1
    finally:
        ws.close()

    return 0


if __name__ == "__main__":
    sys.exit(main())
