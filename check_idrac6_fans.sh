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

# Step 1: Authenticate and save cookie + response
LOGIN_RESPONSE=$(curl -k -s -c "$COOKIE_JAR" -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "user=${USERNAME}&password=${PASSWORD}" \
  "https://${IDRAC_HOST}/data/login")

# Step 2: Extract ST2 token
ST2=$(echo "$LOGIN_RESPONSE" | grep -oP 'ST2=\K[0-9a-f]+')

if [[ -z "$ST2" ]]; then
  echo "CRITICAL - Failed to extract ST2 token from login response"
  exit $STATE_CRITICAL
fi

# Step 3: Request fan and fan redundancy data
RESPONSE=$(curl -k -s -b "$COOKIE_JAR" -X GET \
  -H "ST2: $ST2" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "data=fans,fansRedundancy" \
  "https://${IDRAC_HOST}/data?get=fans,fansRedundancy")

# Step 4: Logout
curl -k -s -b "$COOKIE_JAR" -X GET "https://${IDRAC_HOST}/data/logout" >/dev/null 2>&1

# Step 5: Check for status "ok" in response
STATUS=$(echo "$RESPONSE" | grep -oP '<status>\K[^<]+')
if [[ "$STATUS" != "ok" ]]; then
  echo "CRITICAL - API returned status: $STATUS"
  exit $STATE_CRITICAL
fi

# Step 6: Ensure xmllint is installed
if ! command -v xmllint >/dev/null 2>&1; then
  echo "UNKNOWN - xmllint command not found"
  exit $STATE_UNKNOWN
fi

# Step 7: Parse fans and fan redundancy sensors

declare -A FAN_STATUS_MAP
declare -A FAN_RPM_MAP

# Parse fans (thresholdSensorList)
FAN_COUNT=$(echo "$RESPONSE" | xmllint --xpath 'count(//thresholdSensorList/sensor)' - 2>/dev/null)

for ((i=1; i<=FAN_COUNT; i++)); do
  FAN_NAME=$(echo "$RESPONSE" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/name)" - 2>/dev/null)
  FAN_STATUS=$(echo "$RESPONSE" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/sensorStatus)" - 2>/dev/null)
  FAN_READING=$(echo "$RESPONSE" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/reading)" - 2>/dev/null)
  FAN_STATUS_MAP["$FAN_NAME"]=$FAN_STATUS
  FAN_RPM_MAP["$FAN_NAME"]=$FAN_READING
done

# Parse fan redundancy sensors (discreteSensorList)
RED_COUNT=$(echo "$RESPONSE" | xmllint --xpath 'count(//discreteSensorList/sensor)' - 2>/dev/null)

for ((i=1; i<=RED_COUNT; i++)); do
  RED_NAME=$(echo "$RESPONSE" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/name)" - 2>/dev/null)
  RED_STATUS=$(echo "$RESPONSE" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/sensorStatus)" - 2>/dev/null)
  FAN_STATUS_MAP["$RED_NAME"]=$RED_STATUS
  FAN_RPM_MAP["$RED_NAME"]=""  # No RPM here, just status
done

# Step 8: Evaluate all sensors and build output

EXIT_STATE=$STATE_OK
OUTPUT=""
PERFDATA=""

# Collect fan names in an array to sort
FAN_NAMES=("${!FAN_STATUS_MAP[@]}")
IFS=$'\n' SORTED_FANS=($(sort <<<"${FAN_NAMES[*]}"))
unset IFS

for FAN in "${SORTED_FANS[@]}"; do
  STATUS="${FAN_STATUS_MAP[$FAN]}"
  RPM="${FAN_RPM_MAP[$FAN]}"

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

  if (( CUR_STATE > EXIT_STATE )); then
    EXIT_STATE=$CUR_STATE
  fi

  if [[ "$RPM" =~ ^[0-9]+$ ]]; then
    OUTPUT+="$FAN $STATUS ($RPM RPM); "
    PERFDATA+="\"$FAN\"=${RPM}RPM "
  else
    # For redundancy sensors with no RPM, add status in output,
    # and add perfdata as 1 for normal, 0 otherwise (example)
    OUTPUT+="$FAN $STATUS; "
    if [[ "${STATUS,,}" == "normal" ]]; then
      PERFDATA+="\"$FAN\"=1 "
    else
      PERFDATA+="\"$FAN\"=0 "
    fi
  fi
done

# Trim trailing space and semicolon
OUTPUT="${OUTPUT%; }"
PERFDATA="${PERFDATA% }"

# Step 9: Nagios output
case $EXIT_STATE in
  $STATE_OK)
    echo "OK - All fans within normal parameters | $PERFDATA"
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

