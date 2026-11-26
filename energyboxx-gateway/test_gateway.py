"""Plain-assert checks for gateway.py. Run: python3 test_gateway.py (needs paho-mqtt and websocket-client)."""

import base64
import json

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
    pub.latest["sensor.p1_import"] = (state, 0)
    pub.resend_stale()
    assert [t for t, *_ in client.sent][-1] == "eb/prod/abc/sensor/p1_import/state"
    assert client.sent[0][1] != state["last_updated"], "resend carries a fresh timestamp"

    client.sent.clear()
    client.connected = False
    pub.latest["sensor.p1_import"] = (state, 0)
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


def test_handle_message():
    client = FakeClient()
    pub = gateway.Publisher("a/b/c")
    pub.client = client
    gateway.handle_message(
        {"id": 2, "type": "result", "success": True, "result": [sensor("sensor.x", "1")]}, pub
    )
    assert "sensor.x" in pub.latest
    gateway.handle_message(
        {"type": "event", "event": {"data": {"entity_id": "sensor.x", "new_state": None}}}, pub
    )
    assert "sensor.x" not in pub.latest

    pub.update(sensor("sensor.gone", "1"))
    gateway.handle_message({"id": 2, "type": "result", "success": True, "result": []}, pub)
    assert "sensor.gone" not in pub.latest, "entities missing from a new snapshot are dropped"


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
