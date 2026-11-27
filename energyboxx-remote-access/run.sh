#!/usr/bin/with-contenv bashio
# shellcheck shell=bash source=notify.sh
source /app/notify.sh

DEFAULT_SERVER="tunnel.grexxconnect.com"
DEFAULT_PORT=7000
# Shared and not secret: the tunnel server checks the per-home secret.
TUNNEL_TOKEN="energyboxx-ha-tunnel"
OPTIONS_FILE="${OPTIONS_FILE:-/data/options.json}"
# Short, so a Home Assistant restart with a changed auth config is caught quickly.
AUTH_CHECK_INTERVAL=15
AUTH_OK_FLAG=/tmp/auth-ok

log_level=$(jq -r '.log_level // "info"' "$OPTIONS_FILE")
bashio::log.level "$log_level"

fail() {
  bashio::log.error "Access code problem: $1"
  notify "Energyboxx Remote Access cannot start: $1. Copy the access code from the Energyboxx platform into the add-on's Configuration tab, then start the add-on again."
  exit 1
}

code=$(jq -r '.access_code // empty' "$OPTIONS_FILE")
code="${code//[[:space:]]/}"
[ -n "$code" ] || fail "no access code is set"
padding=$(( (4 - ${#code} % 4) % 4 ))
if ! json=$(printf '%s%s' "$code" "$(head -c "$padding" /dev/zero | tr '\0' '=')" | tr '_-' '/+' | base64 -d 2>/dev/null) \
  || ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$json"; then
  fail "the access code is not valid"
fi
jq -e 'has("v")' >/dev/null <<<"$json" || fail "the access code is incomplete"
jq -e '.v == 1' >/dev/null <<<"$json" || fail "this access code version is not supported; update the add-on"

home=$(jq -r '.home // empty' <<<"$json")
secret=$(jq -r '.secret // empty' <<<"$json")
server=$(jq -r --arg d "$DEFAULT_SERVER" '.server // $d' <<<"$json")
port=$(jq -r --argjson d "$DEFAULT_PORT" '.port // $d' <<<"$json")
# These end up in TOML and in a hostname, so allow only safe characters.
[[ "$home" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ && "$secret" =~ ^[A-Za-z0-9_-]{16,}$ ]] || fail "the access code is incomplete"
if ! [[ "$server" =~ ^[A-Za-z0-9.-]+$ && "$port" =~ ^[0-9]{1,5}$ ]] || (( port < 1 || port > 65535 )); then
  fail "the access code has an invalid server"
fi

if [ -n "${HA_UPSTREAM:-}" ]; then
  upstream="$HA_UPSTREAM"
else
  scheme=http
  bashio::var.true "$(bashio::core.ssl)" && scheme=https
  upstream="${scheme}://homeassistant:$(bashio::core.port)"
fi
resolver=$(awk '/^nameserver/ {print $2; exit}' /etc/resolv.conf)
[[ "$resolver" == *:* ]] && resolver="[$resolver]"
sed -e "s|__RESOLVER__|${resolver:-127.0.0.11}|" -e "s|__UPSTREAM__|${upstream}|" /app/nginx.conf > /etc/nginx/http.d/default.conf

# Tunnel traffic reaches Home Assistant from this add-on's private IP, which trusted_networks would let in without a password.
auth_problem() {
  local providers types
  providers=$(curl -sk -m 10 "${upstream}/auth/providers") || { echo "unreachable"; return; }
  if jq -e '.code == "onboarding_required"' >/dev/null 2>&1 <<<"$providers"; then
    echo "onboarding"
  elif ! types=$(jq -er '.providers[].type' 2>/dev/null <<<"$providers"); then
    echo "unreachable"
  elif grep -qx trusted_networks <<<"$types"; then
    echo "trusted_networks"
  fi
}

refuse() {
  bashio::log.error "$1"
  notify "Energyboxx Remote Access stopped: $1"
  exit 1
}

check_auth() {
  case "$(auth_problem)" in
    trusted_networks) refuse "Home Assistant lets this add-on's network log in without a password (the trusted_networks auth provider). Remove that network from trusted_networks, restart Home Assistant and start the add-on again." ;;
    onboarding) refuse "Home Assistant is not set up yet. Finish onboarding first, so nobody else can create the owner account through remote access." ;;
    unreachable)
      rm -f "$AUTH_OK_FLAG"
      return 1
      ;;
  esac
  touch "$AUTH_OK_FLAG"
}

rm -f "$AUTH_OK_FLAG"
until check_auth; do
  bashio::log.warning "Waiting for Home Assistant at ${upstream}..."
  sleep "$AUTH_CHECK_INTERVAL"
done

# Fail closed: while the check cannot run, nginx answers 503.
guard_auth() {
  while sleep "$AUTH_CHECK_INTERVAL"; do
    check_auth || true
  done
}

umask 077
cat > /tmp/frpc.toml <<TOML
loginFailExit = false
serverAddr = "${server}"
serverPort = ${port}
auth.token = "${TUNNEL_TOKEN}"
user = "${home}"
metadatas.secret = "${secret}"
transport.heartbeatInterval = 30
transport.tls.trustedCaFile = "/etc/ssl/certs/ca-certificates.crt"
log.to = "console"
log.level = "${log_level/warning/warn}"

[[proxies]]
name = "ui"
type = "http"
localIP = "127.0.0.1"
localPort = 8099
subdomain = "${home}"
TOML

watch_frpc() {
  local notified="" line
  while IFS= read -r line; do
    echo "$line"
    case "$line" in
      *"start proxy success"*)
        notified=""
        bashio::log.info "Remote access is on: Energyboxx support can open this Home Assistant (a Home Assistant login is still required)."
        dismiss_notification
        ;;
      *"unknown home or wrong secret"* | *"may only register its own subdomain"*)
        [ "$notified" = rejected ] && continue
        notified=rejected
        notify "The Energyboxx tunnel rejected the access code. Generate a new code on the Energyboxx platform and paste it in the add-on's Configuration tab."
        ;;
      *"connect to server error"* | *"start error"*)
        [ -n "$notified" ] && continue
        notified=unreachable
        notify "Remote access is not available: the add-on cannot connect to the Energyboxx tunnel (${line##*error: }). It keeps retrying; check your internet connection or contact Energyboxx support."
        ;;
    esac
  done
}

bashio::log.info "Connecting to ${server}:${port} as ${home}..."
nginx -g 'daemon off;' &
frpc -c /tmp/frpc.toml 2>&1 | watch_frpc &
guard_auth &
wait -n
bashio::log.error "nginx, frpc or the login check stopped; stopping the add-on."
exit 1
