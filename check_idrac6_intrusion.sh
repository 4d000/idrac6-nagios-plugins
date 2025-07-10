#!/bin/bash

IDRAC_HOST="$1"
USERNAME="$2"
PASSWORD="$3"

COOKIE_JAR=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

# Step 1: Login and save cookie + response
LOGIN_RESPONSE=$(curl -k -s -c "$COOKIE_JAR" -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "user=${USERNAME}&password=${PASSWORD}" \
  "https://${IDRAC_HOST}/data/login")

ST2=$(echo "$LOGIN_RESPONSE" | grep -oP 'ST2=\K[0-9a-f]+')

if [[ -z "$ST2" ]]; then
  echo "CRITICAL - Login failed, no ST2 token"
  exit 2
fi

# Step 2: Fetch intrusion data
INTRUSION_XML=$(curl -k -s -b "$COOKIE_JAR" -X GET \
  -H "ST2: $ST2" \
  "https://${IDRAC_HOST}/data?get=intrusion")

# Step 3: Logout
curl -k -s -b "$COOKIE_JAR" -X GET "https://${IDRAC_HOST}/data/logout" >/dev/null

# Step 4: Parse XML using xmllint
if ! command -v xmllint >/dev/null 2>&1; then
  echo "UNKNOWN - xmllint command required"
  exit 3
fi

SENSOR_NAME=$(echo "$INTRUSION_XML" | xmllint --xpath 'string(//discreteSensorList/sensor/name)' -)
SENSOR_STATUS=$(echo "$INTRUSION_XML" | xmllint --xpath 'string(//discreteSensorList/sensor/sensorStatus)' -)
SENSOR_READING=$(echo "$INTRUSION_XML" | xmllint --xpath 'string(//discreteSensorList/sensor/reading)' -)

# Evaluate sensor status
if [[ "$SENSOR_STATUS" != "Normal" ]]; then
  echo "CRITICAL - $SENSOR_NAME status: $SENSOR_STATUS, reading: $SENSOR_READING"
  exit 2
fi

# For intrusion sensor, consider anything other than "Chassis is closed" as a warning
if [[ "$SENSOR_READING" != "Chassis is closed" ]]; then
  echo "WARNING - $SENSOR_NAME reading: $SENSOR_READING"
  exit 1
fi

echo "OK - $SENSOR_NAME reading: $SENSOR_READING"
exit 0

