#!/usr/bin/env bash
# Stream Keepsy traces from every connected Android device

#   ./logs.sh -a                       # include every logcat tag
#   ./logs.sh -c -t out/ -n scenario  # clear and save a named capture
#   ./logs.sh -g album.open            # filter lines by literal text

set -uo pipefail

# Mirrors the tag in lib/diagnostics/trace.dart
TRACE_TAG="keepsy.trace"

ALL_TAGS=0
CLEAR_FIRST=0
TEE_DIR=""
GREP_PATTERN=""
RUN_LABEL=""

usage() {
    awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"
    exit "${1:-0}"
}

while getopts ":act:g:n:h" opt; do
    case "$opt" in
        a) ALL_TAGS=1 ;;
        c) CLEAR_FIRST=1 ;;
        t) TEE_DIR="$OPTARG" ;;
        g) GREP_PATTERN="$OPTARG" ;;
        n) RUN_LABEL="$OPTARG" ;;
        h) usage 0 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; usage 1 ;;
        :) echo "Option -$OPTARG needs a value" >&2; usage 1 ;;
    esac
done

if [ -n "$RUN_LABEL" ] && ! [[ "$RUN_LABEL" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "Scenario label may contain only letters, digits, dot, underscore, and dash." >&2
    exit 1
fi

command -v adb >/dev/null 2>&1 || { echo "adb not found on PATH." >&2; exit 1; }

DEVICES=$(adb devices | grep -v "List of devices" | grep "device$" | awk '{print $1}')

if [ -z "$DEVICES" ]; then
    echo "No devices detected. Connect via USB or 'adb connect'." >&2
    exit 1
fi

# Keep each app lifetime in a separate capture directory
if [ -n "$TEE_DIR" ]; then
    STAMP=$(date +%Y%m%d-%H%M%S)
    if [ -n "$RUN_LABEL" ]; then
        TEE_DIR="$TEE_DIR/$STAMP-$RUN_LABEL"
    else
        TEE_DIR="$TEE_DIR/$STAMP"
    fi
    mkdir -p "$TEE_DIR"
    echo "teeing to $TEE_DIR/"
fi

COLOURS=(39 208 42 170 220 51 205 118)
RESET=$'\033[0m'

# Use compact labels while retaining the full serial in the capture header
short_label() {
    local serial="$1"
    if [[ "$serial" == *:* ]]; then
        local host="${serial%%:*}"
        echo "${host##*.}:${serial##*:}"
    else
        echo "${serial: -4}"
    fi
}

PIDS=()

cleanup() {
    trap - INT TERM EXIT
    for pid in "${PIDS[@]:-}"; do
        kill "$pid" 2>/dev/null
    done
    wait 2>/dev/null
    printf '\n%s\n' "log stream closed"
}
trap cleanup INT TERM EXIT

echo "Streaming from:"
i=0
for DEVICE in $DEVICES; do
    LABEL=$(short_label "$DEVICE")
    COLOUR="${COLOURS[$((i % ${#COLOURS[@]}))]}"
    printf '  \033[38;5;%sm%-10s\033[0m %s\n' "$COLOUR" "$LABEL" "$DEVICE"
    i=$((i + 1))
done
echo "(server side: docker logs -f keepsy-server-1 | jq)"
echo

i=0
for DEVICE in $DEVICES; do
    LABEL=$(short_label "$DEVICE")
    COLOUR="${COLOURS[$((i % ${#COLOURS[@]}))]}"
    i=$((i + 1))

    if [ -n "$TEE_DIR" ]; then
        MODEL=$(adb -s "$DEVICE" shell getprop ro.product.model 2>/dev/null | tr -d '\r' | tr ' ' '_')
        ANDROID=$(adb -s "$DEVICE" shell getprop ro.build.version.release 2>/dev/null | tr -d '\r' | tr ' ' '_')
        printf '# keepsy.capture device=%s model=%s android=%s scenario=%s\n' \
            "$LABEL" "${MODEL:-unknown}" "${ANDROID:-unknown}" "${RUN_LABEL:-unlabelled}" \
            > "$TEE_DIR/$LABEL.log"
    fi

    if [ "$CLEAR_FIRST" -eq 1 ]; then
        adb -s "$DEVICE" logcat -c >/dev/null 2>&1
    fi

    # Use -a when crash or ANR lines outside the trace tags are needed
    if [ "$ALL_TAGS" -eq 1 ]; then
        LOGCAT_ARGS=(-v time)
    else
        LOGCAT_ARGS=(-v time -s "$TRACE_TAG:V" "flutter:V")
    fi

    (
        # Deduplicate retained logcat lines replayed after an ADB reconnect
        declare -A SEEN_LINES=()
        # Keep the capture alive across transient USB or wireless interruptions
        while true; do
            adb -s "$DEVICE" wait-for-device >/dev/null 2>&1 || exit 1
            while IFS= read -r line; do
                if [ -n "$line" ]; then
                    if [[ -n "${SEEN_LINES["$line"]+present}" ]]; then
                        continue
                    fi
                    SEEN_LINES["$line"]=1
                fi
                if [ -n "$GREP_PATTERN" ] && ! [[ "$line" == *"$GREP_PATTERN"* ]]; then
                    continue
                fi
                printf '\033[38;5;%sm%-10s\033[0m %s\n' "$COLOUR" "$LABEL" "$line"
                if [ -n "$TEE_DIR" ]; then
                    printf '%s\n' "$line" >> "$TEE_DIR/$LABEL.log"
                fi
            done < <(adb -s "$DEVICE" logcat "${LOGCAT_ARGS[@]}" 2>&1)
            printf '\033[38;5;%sm%-10s\033[0m %s\n' \
                "$COLOUR" "$LABEL" "ADB log stream interrupted; waiting to reconnect..." >&2
            sleep 1
        done
    ) &
    PIDS+=("$!")
done

wait
