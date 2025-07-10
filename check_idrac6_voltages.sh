#!/bin/bash

# Nagios exit codes
STATE_OK=0
STATE_WARNING=1
STATE_CRITICAL=2
STATE_UNKNOWN=3

IDRAC_HOST="$1"
USERNAME="$2"
PASSWORD="$3"

COOKIE_JAR=$(mktemp)

cleanup() {
  rm -f "$COOKIE_JAR"
}
trap cleanup EXIT

# === Step 1: Login ===
LOGIN_RESPONSE=$(curl -k -s -c "$COOKIE_JAR" -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "user=${USERNAME}&password=${PASSWORD}" \
  "https://${IDRAC_HOST}/data/login")

ST2=$(echo "$LOGIN_RESPONSE" | grep -oP 'ST2=\K[0-9a-f]+')

if [[ -z "$ST2" ]]; then
  echo "CRITICAL - Unable to extract ST2 token from login."
  exit $STATE_CRITICAL
fi

# === Step 2: Request voltages data ===
VOLTAGE_DATA=$(curl -k -s -b "$COOKIE_JAR" -X GET \
  -H "ST2: $ST2" \
  "https://${IDRAC_HOST}/data?get=voltages")

curl -k -s -b "$COOKIE_JAR" "https://${IDRAC_HOST}/data/logout" >/dev/null 2>&1

# === Step 3: Check if status ok ===
STATUS=$(echo "$VOLTAGE_DATA" | grep -oP '<status>\K[^<]+')
if [[ "$STATUS" != "ok" ]]; then
  echo "CRITICAL - API returned status: $STATUS"
  exit $STATE_CRITICAL
fi

# === Step 4: Parse sensors ===
if ! command -v xmllint >/dev/null 2>&1; then
  echo "UNKNOWN - xmllint is required but not installed."
  exit $STATE_UNKNOWN
fi

# Declare associative arrays
declare -A SENSOR_STATUS_MAP
declare -A SENSOR_READING_MAP

# Get sensor count
SENSOR_COUNT=$(echo "$VOLTAGE_DATA" | xmllint --xpath 'count(//discreteSensorList/sensor)' - 2>/dev/null)
for ((i=1; i<=SENSOR_COUNT; i++)); do
  NAME=$(echo "$VOLTAGE_DATA" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/name)" - 2>/dev/null)
  SENSOR_STATUS=$(echo "$VOLTAGE_DATA" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/sensorStatus)" - 2>/dev/null)
  READING=$(echo "$VOLTAGE_DATA" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/reading)" - 2>/dev/null)
  SENSOR_STATUS_MAP["$NAME"]=$SENSOR_STATUS
  SENSOR_READING_MAP["$NAME"]=$READING
done

# === Step 5: Evaluate sensors and prepare output ===
EXIT_STATE=$STATE_OK
OUTPUT=""
PERFDATA=""

# Sort sensor names
SENSOR_NAMES=("${!SENSOR_STATUS_MAP[@]}")
IFS=$'\n' SORTED_SENSORS=($(sort <<<"${SENSOR_NAMES[*]}"))
unset IFS

for SENSOR in "${SORTED_SENSORS[@]}"; do
  STATUS="${SENSOR_STATUS_MAP[$SENSOR]}"
  READING="${SENSOR_READING_MAP[$SENSOR]}"

  case "${STATUS,,}" in
    normal)
      CUR_STATE=$STATE_OK
      ;;
    warning)
      CUR_STATE=$STATE_WARNING
      ;;
    critical)
      CUR_STATE=$STATE_CRITICAL
      ;;
    *)
      CUR_STATE=$STATE_UNKNOWN
      ;;
  esac

  # Update global exit state
  if (( CUR_STATE > EXIT_STATE )); then
    EXIT_STATE=$CUR_STATE
  fi

  # Append to output
  OUTPUT+="$SENSOR $STATUS ($READING); "

  # Perfdata: 1 for normal, 0 for warning/critical/unknown
  if [[ "${STATUS,,}" == "normal" ]]; then
    PERF_VALUE=1
  else
    PERF_VALUE=0
  fi
  PERFDATA+="\"$SENSOR\"=$PERF_VALUE "
done

# Trim trailing spaces and semicolons
OUTPUT="${OUTPUT%; }"
PERFDATA="${PERFDATA% }"

# === Step 6: Print final status ===
case $EXIT_STATE in
  $STATE_OK)
    echo "OK - All voltages within normal parameters | $PERFDATA"
    ;;
  $STATE_WARNING)
    echo "WARNING - $OUTPUT | $PERFDATA"
    ;;
  $STATE_CRITICAL)
    echo "CRITICAL - $OUTPUT | $PERFDATA"
    ;;
  *)
    echo "UNKNOWN - $OUTPUT | $PERFDATA"
    ;;
esac

exit $EXIT_STATE

