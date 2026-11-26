#!/usr/bin/env python3
"""Publish Home Assistant energy sensors to the Energyboxx broker.

Topics follow Home Assistant's mqtt_statestream layout, which the Energyboxx
device gateway (energyboxx-mqtt-subscriber) ingests:
<base>/<domain>/<object_id>/{unit_of_measurement,last_updated,state}
"""

import base64
import hashlib
import json
import logging
import math
import os
import sys
import threading
import time
import urllib.request
from datetime import datetime, timezone

import paho.mqtt.client as mqtt
from websocket import WebSocketTimeoutException, create_connection

OPTIONS_FILE = os.environ.get("OPTIONS_FILE", "/data/options.json")
WS_URL = os.environ.get("HA_WS_URL", "ws://supervisor/core/websocket")
API_URL = os.environ.get("HA_API_URL", "http://supervisor/core/api")
CA_FILE = os.environ.get("CA_FILE", "/app/ca.crt")

DEFAULT_HOST = "ess.grexxconnect.com"
DEFAULT_PORT = 8883
DEVICE_CLASSES = {"energy", "power", "gas", "battery"}
# The device gateway drops a home from live community power when its latest reading is older than 30s.
RESEND_AFTER = 20
HA_RETRY_DELAY = 10
HA_PING_AFTER = 10
# Resent values get a fresh timestamp, so stop once Home Assistant itself goes quiet.
HA_SILENCE_LIMIT = 20
NOTIFICATION_ID = "energyboxx_gateway"

log = logging.getLogger("energyboxx_gateway")


class CodeError(ValueError):
    pass


def parse_code(code):
    code = (code or "").strip()
    if not code:
        raise CodeError("no connection code is set")
    try:
        data = json.loads(base64.urlsafe_b64decode(code + "=" * (-len(code) % 4)))
    except ValueError:
        raise CodeError("the connection code is not valid") from None
    if not isinstance(data, dict) or data.get("v") != 1:
        raise CodeError("this connection code version is not supported; update the add-on")
    if not all(isinstance(data.get(key), str) and data[key] for key in ("user", "pass", "base")):
        raise CodeError("the connection code is incomplete")
    segments = data["base"].split("/")
    if len(segments) != 3 or not all(segments) or any(c in data["base"] for c in "+#"):
        raise CodeError("the connection code has an invalid base topic")
    try:
        port = int(data.get("port") or DEFAULT_PORT)
    except (TypeError, ValueError):
        raise CodeError("the connection code has an invalid port") from None
    return {
        "host": data.get("host") or DEFAULT_HOST,
        "port": port,
        "user": data["user"],
        "password": data["pass"],
        "base": data["base"],
    }


def is_number(value):
    try:
        return math.isfinite(float(value))
    except (TypeError, ValueError):
        return False


def is_energy_sensor(state):
    attributes = state.get("attributes") or {}
    return (
        state["entity_id"].startswith("sensor.")
        and attributes.get("device_class") in DEVICE_CLASSES
        and bool(attributes.get("unit_of_measurement"))
        and is_number(state.get("state"))
    )


def topic_root(base, entity_id):
    domain, object_id = entity_id.split(".", 1)
    return "{0}/{1}/{2}".format(base, domain, object_id)


def now_iso():
    return datetime.now(timezone.utc).isoformat()


class Publisher:
    def __init__(self, base):
        self.client = None
        self.base = base
        self.units = {}
        self.latest = {}
        self.resend_all = False

    def update(self, state):
        if is_energy_sensor(state):
            if state["entity_id"] not in self.latest:
                log.info("Sharing %s", state["entity_id"])
            self.publish(state, state["last_updated"])
        elif self.latest.pop(state["entity_id"], None):
            log.info("Stopped sharing %s (state: %s)", state["entity_id"], state.get("state"))

    def forget(self, entity_id):
        self.latest.pop(entity_id, None)

    def publish(self, state, timestamp):
        entity_id = state["entity_id"]
        root = topic_root(self.base, entity_id)
        unit = state["attributes"]["unit_of_measurement"]
        if self.units.get(entity_id) != unit:
            info = self.client.publish(root + "/unit_of_measurement", unit, qos=1, retain=True)
            if info.rc == mqtt.MQTT_ERR_SUCCESS:
                self.units[entity_id] = unit
        self.client.publish(root + "/last_updated", timestamp, qos=1)
        self.client.publish(root + "/state", state["state"], qos=1)
        self.latest[entity_id] = (state, time.monotonic())
        log.debug("%s = %s %s", entity_id, state["state"], unit)

    def resend_stale(self):
        if not self.client.is_connected():
            return
        cutoff = time.monotonic() - RESEND_AFTER
        if self.resend_all:
            # After a reconnect the broker may have lost its retained units.
            self.resend_all = False
            self.units.clear()
            cutoff = math.inf
        for state, sent_at in list(self.latest.values()):
            if sent_at <= cutoff:
                self.publish(state, now_iso())


def call_service(token, service, payload):
    request = urllib.request.Request(
        "{0}/services/persistent_notification/{1}".format(API_URL, service),
        data=json.dumps(payload).encode(),
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
        method="POST",
    )
    try:
        urllib.request.urlopen(request, timeout=10).close()
    except Exception as err:  # noqa: BLE001 - a notification must never stop publishing
        log.warning("Could not update the Home Assistant notification: %s", err)


def call_service_async(token, service, payload):
    # Runs off the paho network thread so a slow HA API cannot stall MQTT keepalives.
    threading.Thread(target=call_service, args=(token, service, payload), daemon=True).start()


def notify(token, message):
    call_service_async(
        token,
        "create",
        {"notification_id": NOTIFICATION_ID, "title": "Energyboxx Gateway", "message": message},
    )


def dismiss(token):
    call_service_async(token, "dismiss", {"notification_id": NOTIFICATION_ID})


def make_client(conn, token, publisher):
    client_id = "energyboxx-gateway-" + hashlib.sha256(conn["base"].encode()).hexdigest()[:12]
    client = mqtt.Client(client_id=client_id, clean_session=True)
    client.username_pw_set(conn["user"], conn["password"])
    client.tls_set(ca_certs=CA_FILE)
    client.reconnect_delay_set(min_delay=1, max_delay=60)
    # Bounds memory during a long broker outage; the resend loop refills the latest values.
    client.max_queued_messages_set(1000)
    rejected = [False]

    def on_connect(_client, _userdata, _flags, rc):
        if rc == 0:
            log.info("Connected to %s:%s", conn["host"], conn["port"])
            rejected[0] = False
            dismiss(token)
            publisher.resend_all = True
        elif rc in (4, 5):
            log.error("Broker rejected the connection code (rc=%s)", rc)
            if rejected[0]:
                return
            rejected[0] = True
            notify(
                token,
                "The Energyboxx broker rejected the connection code. "
                "Generate a new code on the Energyboxx platform and paste it in the add-on's Configuration tab.",
            )
        else:
            log.error("Broker refused the connection (rc=%s)", rc)

    def on_disconnect(_client, _userdata, rc):
        if rc != 0:
            log.warning("Disconnected from the broker (rc=%s); reconnecting.", rc)

    client.on_connect = on_connect
    client.on_disconnect = on_disconnect
    return client


def authenticate(ws, token):
    if json.loads(ws.recv()).get("type") != "auth_required":
        raise ConnectionError("unexpected greeting from Home Assistant")
    ws.send(json.dumps({"type": "auth", "access_token": token}))
    reply = json.loads(ws.recv())
    if reply.get("type") != "auth_ok":
        raise ConnectionError("Home Assistant rejected the token: {0}".format(reply.get("message")))


def run_home_assistant(token, publisher):
    ws = create_connection(WS_URL, timeout=30)
    try:
        authenticate(ws, token)
        ws.send(json.dumps({"id": 1, "type": "subscribe_events", "event_type": "state_changed"}))
        ws.send(json.dumps({"id": 2, "type": "get_states"}))
        ws.settimeout(2)
        log.info("Connected to Home Assistant; watching energy sensors.")
        last_received = last_ping = time.monotonic()
        ping_id = 2
        while True:
            try:
                message = json.loads(ws.recv())
                last_received = time.monotonic()
            except WebSocketTimeoutException:
                message = None
            if message:
                handle_message(message, publisher)
            idle = time.monotonic() - last_received
            if idle > HA_SILENCE_LIMIT:
                raise ConnectionError("Home Assistant stopped responding")
            if idle > HA_PING_AFTER and time.monotonic() - last_ping > HA_PING_AFTER:
                ping_id += 1
                ws.send(json.dumps({"id": ping_id, "type": "ping"}))
                last_ping = time.monotonic()
            publisher.resend_stale()
    finally:
        ws.close()


def handle_message(message, publisher):
    if message.get("type") == "result":
        if not message.get("success"):
            raise ConnectionError("Home Assistant command failed: {0}".format(message.get("error")))
        if message.get("id") == 2:
            states = message.get("result") or []
            for state in states:
                publisher.update(state)
            # Entities removed while disconnected never sent a state_changed event.
            for entity_id in set(publisher.latest) - {state["entity_id"] for state in states}:
                publisher.forget(entity_id)
            log.info("Sharing %d energy sensors.", len(publisher.latest))
    elif message.get("type") == "event":
        data = message["event"]["data"]
        if data.get("new_state") is None:
            publisher.forget(data["entity_id"])
        else:
            publisher.update(data["new_state"])


def main():
    try:
        with open(OPTIONS_FILE) as handle:
            options = json.load(handle)
    except (OSError, ValueError) as err:
        print("Cannot read {0}: {1}".format(OPTIONS_FILE, err), flush=True)
        return 1

    logging.basicConfig(
        level=getattr(logging, str(options.get("log_level") or "info").upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s",
        stream=sys.stdout,
    )

    token = os.environ.get("SUPERVISOR_TOKEN")
    if not token:
        log.error("SUPERVISOR_TOKEN missing; cannot reach Home Assistant.")
        return 1

    try:
        conn = parse_code(options.get("connection_code"))
    except CodeError as err:
        log.error("Connection code problem: %s", err)
        notify(
            token,
            "The Energyboxx Gateway cannot start: {0}. Copy the connection code from the Energyboxx "
            "platform into the add-on's Configuration tab, then start the add-on again.".format(err),
        )
        return 1

    publisher = Publisher(conn["base"])
    client = make_client(conn, token, publisher)
    publisher.client = client
    log.info("Connecting to %s:%s", conn["host"], conn["port"])
    client.connect_async(conn["host"], conn["port"], keepalive=60)
    client.loop_start()

    while True:
        try:
            run_home_assistant(token, publisher)
        except Exception as err:  # noqa: BLE001 - keep publishing after any HA hiccup
            log.warning("Home Assistant connection lost (%s); retrying in %ss.", err, HA_RETRY_DELAY)
        time.sleep(HA_RETRY_DELAY)


if __name__ == "__main__":
    sys.exit(main())
