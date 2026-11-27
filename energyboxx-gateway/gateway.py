#!/usr/bin/env python3
"""Publish Home Assistant energy sensors to the Energyboxx broker.

Topics follow Home Assistant's mqtt_statestream layout, which the Energyboxx
device gateway (energyboxx-mqtt-subscriber) ingests:
<base>/<domain>/<object_id>/{unit_of_measurement,last_updated,state}
plus a retained <base>/inventory that the platform's onboarding page reads.
"""

import base64
import hashlib
import itertools
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
INVENTORY_REFRESH = 15 * 60
INVENTORY_REQUESTS = {
    "energy": "energy/get_prefs",
    "entities": "config/entity_registry/list",
    "devices": "config/device_registry/list",
}

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


def is_candidate(state):
    attributes = state.get("attributes") or {}
    return (
        state["entity_id"].startswith("sensor.")
        and attributes.get("device_class") in DEVICE_CLASSES
        and bool(attributes.get("unit_of_measurement"))
    )


def is_energy_sensor(state):
    return is_candidate(state) and is_number(state.get("state"))


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
        self.inventory_sent = None

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
            self.inventory_sent = None
            cutoff = math.inf
        for state, sent_at in list(self.latest.values()):
            if sent_at <= cutoff:
                self.publish(state, now_iso())

    def publish_inventory(self, inventory):
        if inventory == self.inventory_sent or not self.client.is_connected():
            return
        payload = json.dumps(dict(inventory, generated_at=now_iso()), sort_keys=True)
        rc = self.client.publish(self.base + "/inventory", payload, qos=1, retain=True).rc
        # NO_CONN still queues the message; a reconnect clears inventory_sent anyway.
        if rc in (mqtt.MQTT_ERR_SUCCESS, mqtt.MQTT_ERR_NO_CONN):
            self.inventory_sent = inventory
            log.info(
                "Sent inventory: %d candidate sensors, energy dashboard %s.",
                len(inventory["sensors"]),
                "configured" if inventory["energy"] else "not configured",
            )


def energy_sources(prefs):
    """Only the sensor choices per source; costs, prices and per-device consumption stay home."""
    if not prefs:
        return None

    def keep(item):
        return {k: v for k, v in item.items() if k == "type" or (k.startswith("stat_") and k != "stat_cost")}

    sources = []
    for source in prefs.get("energy_sources") or []:
        entry = keep(source)
        for flow in ("flow_from", "flow_to"):
            if flow in source:
                entry[flow] = [keep(item) for item in source[flow]]
        sources.append(entry)
    return {"energy_sources": sources}


class Inventory:
    """Candidate sensors (also unavailable ones), their devices and the energy dashboard setup."""

    def __init__(self):
        self.sensors = {}
        self.parts = {}
        self.loaded = False

    def track(self, state):
        if not is_candidate(state):
            self.forget(state["entity_id"])
            return
        attributes = state["attributes"]
        self.sensors[state["entity_id"]] = {
            "name": attributes.get("friendly_name"),
            "device_class": attributes.get("device_class"),
            "state_class": attributes.get("state_class"),
            "unit": attributes.get("unit_of_measurement"),
        }

    def forget(self, entity_id):
        self.sensors.pop(entity_id, None)

    def ready(self):
        return self.loaded and all(kind in self.parts for kind in INVENTORY_REQUESTS)

    def build(self):
        devices = {device["id"]: device for device in self.parts["devices"] or []}
        device_ids = {entry["entity_id"]: entry.get("device_id") for entry in self.parts["entities"] or []}
        sensors = []
        for entity_id, info in sorted(self.sensors.items()):
            device = devices.get(device_ids.get(entity_id))
            if device:
                device = {
                    "name": device.get("name_by_user") or device.get("name"),
                    "manufacturer": device.get("manufacturer"),
                    "model": device.get("model"),
                }
            sensors.append(dict(info, entity_id=entity_id, device=device))
        return {"v": 1, "energy": energy_sources(self.parts["energy"]), "sensors": sensors}


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


def run_home_assistant(token, publisher, inventory):
    ws = create_connection(WS_URL, timeout=30)
    try:
        authenticate(ws, token)
        ids = itertools.count(1)
        requests = {}

        def send(kind, command, **fields):
            message_id = next(ids)
            if kind:
                requests[message_id] = kind
            ws.send(json.dumps(dict(fields, id=message_id, type=command)))

        send("subscribe", "subscribe_events", event_type="state_changed")
        send("states", "get_states")
        ws.settimeout(2)
        log.info("Connected to Home Assistant; watching energy sensors.")
        last_received = last_ping = time.monotonic()
        last_inventory = -math.inf
        while True:
            try:
                message = json.loads(ws.recv())
                last_received = time.monotonic()
            except WebSocketTimeoutException:
                message = None
            if message:
                handle_message(message, publisher, inventory, requests)
            idle = time.monotonic() - last_received
            if idle > HA_SILENCE_LIMIT:
                raise ConnectionError("Home Assistant stopped responding")
            if idle > HA_PING_AFTER and time.monotonic() - last_ping > HA_PING_AFTER:
                send(None, "ping")
                last_ping = time.monotonic()
            if time.monotonic() - last_inventory > INVENTORY_REFRESH:
                for kind, command in INVENTORY_REQUESTS.items():
                    send(kind, command)
                last_inventory = time.monotonic()
            publisher.resend_stale()
            if inventory.ready():
                publisher.publish_inventory(inventory.build())
    finally:
        ws.close()


def handle_message(message, publisher, inventory, requests):
    if message.get("type") == "result":
        kind = requests.pop(message.get("id"), None)
        if kind in INVENTORY_REQUESTS:
            error = message.get("error") or {}
            if not message.get("success"):
                # energy/get_prefs answers not_found when the energy dashboard was never set up.
                not_set_up = kind == "energy" and error.get("code") == "not_found"
                (log.debug if not_set_up else log.warning)("No %s for the inventory: %s", kind, error)
            inventory.parts[kind] = message.get("result") if message.get("success") else None
            return
        if not message.get("success"):
            raise ConnectionError("Home Assistant command failed: {0}".format(message.get("error")))
        if kind == "states":
            states = message.get("result") or []
            for state in states:
                publisher.update(state)
                inventory.track(state)
            inventory.loaded = True
            # Entities removed while disconnected never sent a state_changed event.
            for entity_id in (set(publisher.latest) | set(inventory.sensors)) - {s["entity_id"] for s in states}:
                publisher.forget(entity_id)
                inventory.forget(entity_id)
            log.info("Sharing %d energy sensors.", len(publisher.latest))
    elif message.get("type") == "event":
        data = message["event"]["data"]
        if data.get("new_state") is None:
            publisher.forget(data["entity_id"])
            inventory.forget(data["entity_id"])
        else:
            publisher.update(data["new_state"])
            inventory.track(data["new_state"])


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
    inventory = Inventory()
    log.info("Connecting to %s:%s", conn["host"], conn["port"])
    client.connect_async(conn["host"], conn["port"], keepalive=60)
    client.loop_start()

    while True:
        try:
            run_home_assistant(token, publisher, inventory)
        except Exception as err:  # noqa: BLE001 - keep publishing after any HA hiccup
            log.warning("Home Assistant connection lost (%s); retrying in %ss.", err, HA_RETRY_DELAY)
        time.sleep(HA_RETRY_DELAY)


if __name__ == "__main__":
    sys.exit(main())
