"""Plain-assert checks for gateway.py. Run: python3 test_gateway.py (needs paho-mqtt and websocket-client)."""

import base64
import json
import math

import gateway


def code(**data):
    raw = json.dumps(data).encode()
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def raises(fn, text):
    try:
        fn()
    except gateway.CodeError as err:
        assert text in str(err), err
    else:
        raise AssertionError("expected CodeError")


class FakeClient:
    def __init__(self):
        self.sent = []
        self.connected = True

    def publish(self, topic, payload, qos=0, retain=False):
        self.sent.append((topic, payload, qos, retain))
        return type("Info", (), {"rc": gateway.mqtt.MQTT_ERR_SUCCESS})()

    def is_connected(self):
        return self.connected


def sensor(entity_id, state, unit="kWh", device_class="energy"):
    return {
        "entity_id": entity_id,
        "state": state,
        "last_updated": "2026-11-26T10:00:00+00:00",
        "attributes": {"unit_of_measurement": unit, "device_class": device_class},
    }


def test_parse_code():
    conn = gateway.parse_code(code(v=1, user="u", **{"pass": "p"}, base="eb/prod/abc"))
    assert conn == {
        "host": "ess.grexxconnect.com",
        "port": 8883,
        "user": "u",
        "password": "p",
        "base": "eb/prod/abc",
    }
    assert gateway.parse_code(code(v=1, user="u", **{"pass": "p"}, base="a/b/c", host="h", port=1))["port"] == 1
    raises(lambda: gateway.parse_code(""), "no connection code")
    raises(lambda: gateway.parse_code("not-base64!"), "not valid")
    raises(lambda: gateway.parse_code(code(v=2, user="u", **{"pass": "p"}, base="a/b/c")), "version")
    raises(lambda: gateway.parse_code(code(v=1, user="u", base="a/b/c")), "incomplete")
    raises(lambda: gateway.parse_code(code(v=1, user="u", **{"pass": "p"}, base="a/b")), "base topic")
    raises(lambda: gateway.parse_code(code(v=1, user="u", **{"pass": "p"}, base="a/#/c")), "base topic")
    raises(lambda: gateway.parse_code(code(v=1, user="u", **{"pass": "p"}, base="a//c")), "base topic")
    raises(lambda: gateway.parse_code(code(v=1, user="u", **{"pass": "p"}, base="a/b/c", port="x")), "port")


def test_filter():
    assert gateway.is_energy_sensor(sensor("sensor.p1_import", "123.4"))
    assert gateway.is_energy_sensor(sensor("sensor.power", "-850", "W", "power"))
    assert not gateway.is_energy_sensor(sensor("sensor.p1_import", "unavailable"))
    assert not gateway.is_energy_sensor(sensor("sensor.p1_import", "nan"))
    assert not gateway.is_energy_sensor(sensor("sensor.temp", "21", "°C", "temperature"))
    assert not gateway.is_energy_sensor(sensor("sensor.p1_import", "1", ""))
    assert not gateway.is_energy_sensor(sensor("input_number.p1", "1"))


def test_publisher():
    client = FakeClient()
    pub = gateway.Publisher("eb/prod/abc")
    pub.client = client

    pub.update(sensor("sensor.p1_import", "100"))
    assert client.sent == [
        ("eb/prod/abc/sensor/p1_import/unit_of_measurement", "kWh", 1, True),
        ("eb/prod/abc/sensor/p1_import/last_updated", "2026-11-26T10:00:00+00:00", 1, False),
        ("eb/prod/abc/sensor/p1_import/state", "100", 1, False),
    ]

    client.sent.clear()
    pub.update(sensor("sensor.p1_import", "101"))
    assert [t for t, *_ in client.sent] == [
        "eb/prod/abc/sensor/p1_import/last_updated",
        "eb/prod/abc/sensor/p1_import/state",
    ], "unit is only sent when it changes"

    client.sent.clear()
    pub.resend_stale()
    assert client.sent == [], "fresh values are not resent"

    state, _ = pub.latest["sensor.p1_import"]
    pub.latest["sensor.p1_import"] = (state, -math.inf)
    pub.resend_stale()
    assert [t for t, *_ in client.sent][-1] == "eb/prod/abc/sensor/p1_import/state"
    assert client.sent[0][1] != state["last_updated"], "resend carries a fresh timestamp"

    client.sent.clear()
    client.connected = False
    pub.latest["sensor.p1_import"] = (state, -math.inf)
    pub.resend_stale()
    assert client.sent == [], "nothing is queued while disconnected"

    client.connected = True
    pub.resend_all = True
    pub.resend_stale()
    assert client.sent[0][0].endswith("/unit_of_measurement"), "reconnect resends the unit"

    client.sent.clear()
    pub.update(sensor("sensor.p1_import", "unavailable"))
    assert "sensor.p1_import" not in pub.latest and client.sent == []
    pub.latest.clear()
    pub.update(sensor("sensor.temp", "21", "°C", "temperature"))
    assert client.sent == [], "non-energy sensors are never published"


def result(message_id, data, success=True):
    return {"id": message_id, "type": "result", "success": success, "result": data}


def test_handle_message():
    client = FakeClient()
    pub = gateway.Publisher("a/b/c")
    pub.client = client
    inv = gateway.Inventory()
    gateway.handle_message(result(2, [sensor("sensor.x", "1")]), pub, inv, {2: "states"})
    assert "sensor.x" in pub.latest and "sensor.x" in inv.sensors and inv.loaded
    gateway.handle_message(
        {"type": "event", "event": {"data": {"entity_id": "sensor.x", "new_state": None}}}, pub, inv, {}
    )
    assert "sensor.x" not in pub.latest and "sensor.x" not in inv.sensors

    pub.update(sensor("sensor.gone", "1"))
    inv.track(sensor("sensor.gone", "1"))
    gateway.handle_message(result(5, []), pub, inv, {5: "states"})
    assert "sensor.gone" not in pub.latest, "entities missing from a new snapshot are dropped"
    assert "sensor.gone" not in inv.sensors

    try:
        gateway.handle_message(result(1, None, success=False), pub, inv, {1: "subscribe"})
    except ConnectionError:
        pass
    else:
        raise AssertionError("a failed subscription reconnects")


def test_inventory():
    client = FakeClient()
    pub = gateway.Publisher("a/b/c")
    pub.client = client
    inv = gateway.Inventory()
    requests = {3: "energy", 4: "entities", 5: "devices"}
    gateway.handle_message(result(2, [sensor("sensor.p1", "unavailable")]), pub, inv, {2: "states"})
    assert "sensor.p1" not in pub.latest and "sensor.p1" in inv.sensors, "unavailable sensors stay listed"
    assert not inv.ready()

    gateway.handle_message(result(3, None, success=False), pub, inv, requests)
    assert gateway.energy_sources({
        "energy_sources": [
            {"type": "grid", "flow_from": [{"stat_energy_from": "sensor.in", "stat_cost": "sensor.c",
                                            "entity_energy_price": "sensor.p"}], "cost_adjustment_day": 1},
            {"type": "battery", "stat_energy_from": "sensor.out", "stat_energy_to": "sensor.in2"},
        ],
        "device_consumption": [{"stat_consumption": "sensor.washer"}],
    }) == {"energy_sources": [
        {"type": "grid", "flow_from": [{"stat_energy_from": "sensor.in"}]},
        {"type": "battery", "stat_energy_from": "sensor.out", "stat_energy_to": "sensor.in2"},
    ]}, "costs, prices and devices are not shared"
    gateway.handle_message(result(4, [{"entity_id": "sensor.p1", "device_id": "d1"}]), pub, inv, requests)
    gateway.handle_message(
        result(5, [{"id": "d1", "name": "P1", "name_by_user": None, "manufacturer": "HW", "model": "P1"}]),
        pub, inv, requests,
    )
    assert inv.ready() and not requests
    assert inv.build() == {
        "v": 1,
        "energy": None,
        "sensors": [{
            "entity_id": "sensor.p1", "name": None, "device_class": "energy", "state_class": None,
            "unit": "kWh", "device": {"name": "P1", "manufacturer": "HW", "model": "P1"},
        }],
    }

    pub.publish_inventory(inv.build())
    topic, payload, qos, retain = client.sent[-1]
    assert (topic, qos, retain) == ("a/b/c/inventory", 1, True)
    assert json.loads(payload)["generated_at"]
    client.sent.clear()
    pub.publish_inventory(inv.build())
    assert client.sent == [], "unchanged inventory is not resent"

    inv.track(sensor("sensor.p1", "5"))
    pub.publish_inventory(inv.build())
    assert client.sent == [], "a new value alone does not change the inventory"

    pub.resend_all = True
    pub.resend_stale()
    pub.publish_inventory(inv.build())
    assert client.sent[-1][0] == "a/b/c/inventory", "reconnect resends the inventory"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
