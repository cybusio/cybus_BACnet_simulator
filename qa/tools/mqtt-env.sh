#!/usr/bin/env bash
# Build the mosquitto connection args for dev (plain) OR production (TLS) from env, so
# the same e2e battery can verify data on either broker. Source it, then use $MQTT_ARGS:
#
#   . qa/tools/mqtt-env.sh
#   mosquitto_sub $MQTT_ARGS -t 'services/#'
#   mosquitto_pub $MQTT_ARGS -t 'services/x/set' -m 1
#
# Dev (default):  plain mqtt://localhost:1883, admin/admin — nothing to set.
# Production:     MQTT_SCHEME=mqtts  (TLS data plane, default port 8883)
#                 MQTT_HOST=<connectware-host>  MQTT_CA=/path/connectware-ca.pem
#                 MQTT_USER=<cw-user>  MQTT_PASS=<pass>          # broker user/pass over TLS
#     or mTLS:    MQTT_CLIENTCERT=/path/client.pem  MQTT_CLIENTKEY=/path/client.key
#                 (the client cert CN must be in the Connectware CA chain)
#
# Also exports CW_CURL_CA: pass it to curl for the HTTPS API instead of -k —
#   curl $CW_CURL_CA https://$CW_HOST/api/...   (CW_CA set => --cacert, else -k for dev).
# default user/pass only when UNSET (`=`), not when empty — so an mTLS-only caller can set
# MQTT_USER="" to drop user/pass and authenticate by client cert alone.
: "${MQTT_HOST:=localhost}"; : "${MQTT_USER=admin}"; : "${MQTT_PASS=admin}"; : "${MQTT_SCHEME:=mqtt}"
if [ "$MQTT_SCHEME" = "mqtts" ]; then
  : "${MQTT_PORT:=8883}"
  [ -n "${MQTT_CA:-}" ] || { echo "mqtt-env: MQTT_SCHEME=mqtts requires MQTT_CA (broker CA chain)" >&2; return 1 2>/dev/null || exit 1; }
  MQTT_ARGS="-h $MQTT_HOST -p $MQTT_PORT --cafile $MQTT_CA"
  if [ -n "${MQTT_CLIENTCERT:-}" ]; then
    [ -n "${MQTT_CLIENTKEY:-}" ] || { echo "mqtt-env: MQTT_CLIENTCERT needs MQTT_CLIENTKEY" >&2; return 1 2>/dev/null || exit 1; }
    MQTT_ARGS="$MQTT_ARGS --cert $MQTT_CLIENTCERT --key $MQTT_CLIENTKEY"
  fi
  [ -n "${MQTT_USER:-}" ] && MQTT_ARGS="$MQTT_ARGS -u $MQTT_USER -P $MQTT_PASS"
else
  : "${MQTT_PORT:=1883}"
  MQTT_ARGS="-h $MQTT_HOST -p $MQTT_PORT -u $MQTT_USER -P $MQTT_PASS"
fi
CW_CURL_CA="-k"; [ -n "${CW_CA:-}" ] && CW_CURL_CA="--cacert $CW_CA"
# Don't silently fail open on the API: in production (mqtts) without CW_CA the broker is
# verified but the API would fall back to -k. Warn loudly so it isn't missed.
[ "$MQTT_SCHEME" = "mqtts" ] && [ -z "${CW_CA:-}" ] && \
  echo "mqtt-env: WARNING — mqtts data plane but no CW_CA set; the HTTPS API will use -k (no cert verification)." >&2
export MQTT_ARGS CW_CURL_CA
