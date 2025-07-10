#!/bin/bash

# Nagios states
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

# --- Step 1: Login ---
LOGIN_RESPONSE=$(curl -k -s -c "$COOKIE_JAR" -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "user=${USERNAME}&password=${PASSWORD}" \
  "https://${IDRAC_HOST}/data/login")

ST2=$(echo "$LOGIN_RESPONSE" | grep -oP 'ST2=\K[0-9a-f]+')

if [[ -z "$ST2" ]]; then
  echo "CRITICAL - Failed to extract ST2 token from login."
  exit $STATE_CRITICAL
fi

# --- Step 2: Get combined data ---
DATA=$(curl -k -s -b "$COOKIE_JAR" -X GET \
  -H "ST2: $ST2" \
  "https://${IDRAC_HOST}/data?get=powermonitordata,systemLevel,voltages")

curl -k -s -b "$COOKIE_JAR" "https://${IDRAC_HOST}/data/logout" >/dev/null 2>&1

# --- Step 3: Check API status ---
STATUS=$(echo "$DATA" | grep -oP '<status>\K[^<]+')
if [[ "$STATUS" != "ok" ]]; then
  echo "CRITICAL - API returned status: $STATUS"
  exit $STATE_CRITICAL
fi

# --- Dependencies ---
if ! command -v xmllint >/dev/null 2>&1; then
  echo "UNKNOWN - xmllint is required but not installed."
  exit $STATE_UNKNOWN
fi

EXIT_STATE=$STATE_OK
OUTPUT=""
PERFDATA=""

# --- Step 4: Parse powermonitordata ---
# Extract some key power monitor values (example: ipowerWatts1, ampReading1..4)
PM_IPOWER=$(echo "$DATA" | xmllint --xpath 'string(//powermonitordata/ipowerWatts1)' - 2>/dev/null)
PM_AMP1=$(echo "$DATA" | xmllint --xpath 'string(//powermonitordata/ampReading1)' - 2>/dev/null)
PM_AMP2=$(echo "$DATA" | xmllint --xpath 'string(//powermonitordata/ampReading2)' - 2>/dev/null)
PM_AMP3=$(echo "$DATA" | xmllint --xpath 'string(//powermonitordata/ampReading3)' - 2>/dev/null)
PM_AMP4=$(echo "$DATA" | xmllint --xpath 'string(//powermonitordata/ampReading4)' - 2>/dev/null)

OUTPUT+="Power Monitor Watts=${PM_IPOWER}W, Amps=[${PM_AMP1},${PM_AMP2},${PM_AMP3},${PM_AMP4}]; "

PERFDATA+="powermonitor_watts=${PM_IPOWER}A amps1=${PM_AMP1} amps2=${PM_AMP2} amps3=${PM_AMP3} amps4=${PM_AMP4} "

# --- Step 5: Parse systemLevel sensor (thresholdSensorList) ---
SYS_SENSOR_COUNT=$(echo "$DATA" | xmllint --xpath 'count(//thresholdSensorList/sensor)' - 2>/dev/null)
for ((i=1; i<=SYS_SENSOR_COUNT; i++)); do
  NAME=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/name)" - 2>/dev/null)
  STATUS=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/sensorStatus)" - 2>/dev/null)
  READING=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/reading)" - 2>/dev/null)
  UNITS=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/units)" - 2>/dev/null)
  MINWARN=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/minWarning)" - 2>/dev/null)
  MAXWARN=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/maxWarning)" - 2>/dev/null)
  MINFAIL=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/minFailure)" - 2>/dev/null)
  MAXFAIL=$(echo "$DATA" | xmllint --xpath "string(//thresholdSensorList/sensor[$i]/maxFailure)" - 2>/dev/null)

  # Evaluate thresholds if numeric
  WARN=0
  CRIT=0
  if [[ "$READING" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    # Check max failure
    if [[ "$MAXFAIL" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$READING > $MAXFAIL" | bc -l) )); then
      CRIT=1
    elif [[ "$MAXWARN" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$READING > $MAXWARN" | bc -l) )); then
      WARN=1
    fi
    # Check min failure
    if [[ "$MINFAIL" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$READING < $MINFAIL" | bc -l) )); then
      CRIT=1
    elif [[ "$MINWARN" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(echo "$READING < $MINWARN" | bc -l) )); then
      WARN=1
    fi
  fi

  if (( CRIT == 1 )); then
    CUR_STATE=$STATE_CRITICAL
  elif (( WARN == 1 )); then
    CUR_STATE=$STATE_WARNING
  else
    # fallback to sensorStatus text
    case "${STATUS,,}" in
      normal) CUR_STATE=$STATE_OK ;;
      warning) CUR_STATE=$STATE_WARNING ;;
      critical) CUR_STATE=$STATE_CRITICAL ;;
      *) CUR_STATE=$STATE_UNKNOWN ;;
    esac
  fi

  [[ $CUR_STATE -gt $EXIT_STATE ]] && EXIT_STATE=$CUR_STATE

  OUTPUT+="$NAME $STATUS ($READING$UNITS); "
  PERFDATA+="\"$NAME\"=$READING$UNITS "

done

# --- Step 6: Parse discrete voltage sensors ---
DISCRETE_COUNT=$(echo "$DATA" | xmllint --xpath 'count(//discreteSensorList/sensor)' - 2>/dev/null)
declare -A SENSOR_STATUS_MAP
declare -A SENSOR_READING_MAP

for ((i=1; i<=DISCRETE_COUNT; i++)); do
  NAME=$(echo "$DATA" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/name)" - 2>/dev/null)
  STATUS=$(echo "$DATA" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/sensorStatus)" - 2>/dev/null)
  READING=$(echo "$DATA" | xmllint --xpath "string(//discreteSensorList/sensor[$i]/reading)" - 2>/dev/null)
  SENSOR_STATUS_MAP["$NAME"]=$STATUS
  SENSOR_READING_MAP["$NAME"]=$READING
done

# Sort sensors alphabetically
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

  if (( CUR_STATE > EXIT_STATE )); then
    EXIT_STATE=$CUR_STATE
  fi

  OUTPUT+="$SENSOR $STATUS ($READING); "
  # Perfdata 1 if normal else 0
  if [[ "${STATUS,,}" == "normal" ]]; then
    PERF_VAL=1
  else
    PERF_VAL=0
  fi
  PERFDATA+="\"$SENSOR\"=$PERF_VAL "
done

# Clean trailing semicolons and spaces
OUTPUT="${OUTPUT%; }"
PERFDATA="${PERFDATA% }"

# --- Step 7: Output final result ---
case $EXIT_STATE in
  $STATE_OK)
    echo "OK - All power and voltage sensors normal | $PERFDATA"
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

