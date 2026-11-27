#!/usr/bin/env bash
# Sourced by run.sh; shows add-on problems in the HA notification panel.

NOTIFICATION_ID="energyboxx_remote_access"

notify() {
  local payload
  payload=$(jq -nc --arg id "$NOTIFICATION_ID" --arg msg "$1" \
    '{notification_id: $id, title: "Energyboxx Remote Access", message: $msg}')
  curl -s -o /dev/null -m 10 -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "${SUPERVISOR_API:-http://supervisor/core/api}/services/persistent_notification/create" \
    -d "$payload" || true
}

dismiss_notification() {
  curl -s -o /dev/null -m 10 -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    "${SUPERVISOR_API:-http://supervisor/core/api}/services/persistent_notification/dismiss" \
    -d "{\"notification_id\": \"$NOTIFICATION_ID\"}" || true
}
