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

# Step 2: Fetch temperature data
TEMP_XML=$(curl -k -s -b "$COOKIE_JAR" -X GET \
  -H "ST2: $ST2" \
  "https://${IDRAC_HOST}/data?get=temperatures")

# Step 3: Logout
curl -k -s -b "$COOKIE_JAR" -X GET "https://${IDRAC_HOST}/data/logout" >/dev/null

# Step 4: Parse XML using xmllint
if ! command -v xmllint >/dev/null 2>&1; then
  echo "UNKNOWN - xmllint command required"
  exit 3
fi

NAME=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/name)' -)
STATUS=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/sensorStatus)' -)
READING=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/reading)' -)
UNITS=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/units)' -)
MINWARN=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/minWarning)' -)
MAXWARN=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/maxWarning)' -)
MINFAIL=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/minFailure)' -)
MAXFAIL=$(echo "$TEMP_XML" | xmllint --xpath 'string(//thresholdSensorList/sensor/maxFailure)' -)

# Validate reading is numeric
if ! [[ "$READING" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
  echo "UNKNOWN - Invalid reading: $READING"
  exit 3
fi

STATE=0 # OK

# Check thresholds with bc for floating point comparison
if (( $(echo "$READING < $MINFAIL" | bc -l) )) || (( $(echo "$READING > $MAXFAIL" | bc -l) )); then
  STATE=2
elif (( $(echo "$READING < $MINWARN" | bc -l) )) || (( $(echo "$READING > $MAXWARN" | bc -l) )); then
  STATE=1
fi

# Output Nagios formatted message with perfdata
case $STATE in
  0) echo "OK - $NAME temperature is $READING°$UNITS | '$NAME'=${READING}°${UNITS}";;
  1) echo "WARNING - $NAME temperature is $READING°$UNITS (warning thresholds $MINWARN-$MAXWARN) | '$NAME'=${READING}°${UNITS}";;
  2) echo "CRITICAL - $NAME temperature is $READING°$UNITS (failure thresholds $MINFAIL-$MAXFAIL) | '$NAME'=${READING}°${UNITS}";;
esac

exit $STATE

