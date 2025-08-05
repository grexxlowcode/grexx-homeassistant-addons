#!/usr/bin/env python3
import json
import os
import requests
import yaml
import time

# Setup for Home Assistant API
HA_URL = os.environ.get('SUPERVISOR_API', 'http://supervisor/core/api')
TOKEN = os.environ.get('SUPERVISOR_TOKEN')
HEADERS = {
    'Authorization': f'Bearer {TOKEN}',
    'Content-Type': 'application/json',
}

# Wait for Home Assistant to be fully available
def wait_for_ha():
    max_retries = 10
    retries = 0
    while retries < max_retries:
        try:
            response = requests.get(f"{HA_URL}/", headers=HEADERS)
            if response.status_code == 200:
                print("Home Assistant is available")
                return True
            else:
                print(f"Home Assistant not yet available, status code: {response.status_code}")
        except Exception as e:
            print(f"Error connecting to Home Assistant: {e}")

        retries += 1
        time.sleep(10)

    print("Failed to connect to Home Assistant after maximum retries")
    return False

def setup_mqtt_statestream():
    print("Setting up MQTT Statestream integration...")

    # Read configuration from the addon config
    with open('/data/options.json', 'r') as f:
        options = json.load(f)

    include_domains = options.get('mqtt_statestream_include_domains', ['switch', 'light', 'climate'])
    base_topic = options.get('mqtt_statestream_base_topic', 'homeassistant')

    # Configure MQTT Statestream
    statestream_config = {
        "base_topic": base_topic,
        "include": {
            "domains": include_domains
        }
    }

    try:
        response = requests.post(
            f"{HA_URL}/services/mqtt/publish",
            headers=HEADERS,
            json={
                "topic": "homeassistant/mqtt_statestream/config",
                "payload": json.dumps(statestream_config),
                "retain": True
            }
        )

        if response.status_code in [200, 201]:
            print("MQTT Statestream configuration sent successfully")
        else:
            print(f"Failed to configure MQTT Statestream: {response.status_code} - {response.text}")

    except Exception as e:
        print(f"Error setting up MQTT Statestream: {e}")

def setup_service_call_automation():
    print("Setting up service call automation...")

    # Load the automation from file
    with open('/automation.yaml', 'r') as f:
        automation = yaml.safe_load(f)

    try:
        # Check if the automation already exists
        response = requests.get(
            f"{HA_URL}/config/automation/config",
            headers=HEADERS
        )

        if response.status_code == 200:
            automations = response.json()

            # Check if our automation already exists
            exists = False
            for existing in automations:
                if existing.get('id') == 'grexx-services':
                    exists = True
                    break

            if not exists:
                # Create the automation
                response = requests.post(
                    f"{HA_URL}/config/automation/config",
                    headers=HEADERS,
                    json=automation
                )

                if response.status_code in [200, 201]:
                    print("Service call automation created successfully")
                else:
                    print(f"Failed to create automation: {response.status_code} - {response.text}")
            else:
                print("Service call automation already exists")
        else:
            print(f"Failed to check existing automations: {response.status_code} - {response.text}")

    except Exception as e:
        print(f"Error setting up service call automation: {e}")

if __name__ == "__main__":
    if wait_for_ha():
        setup_mqtt_statestream()
        setup_service_call_automation()
    else:
        print("Could not connect to Home Assistant, exiting.")
