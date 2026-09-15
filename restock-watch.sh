#!/usr/bin/env bash
# restock-watch — polls a product page and notifies you the moment it leaves
# the "sold out" state. Bash + curl, nothing else. Meant to run from cron
# every few minutes.
#
#   restock-watch.sh [-c FILE] [--dry-run | --test | --status | --reset]
#
# See restock-watch.conf.example for every setting, README.md for the idea.
set -u

VERSION="1.0.0"
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONF="$SCRIPT_DIR/restock-watch.conf"
MODE=run

while [ $# -gt 0 ]; do
    case "$1" in
        -c|--config) CONF="$2"; shift 2 ;;
        --dry-run)   MODE=dry; shift ;;
        --test)      MODE=test; shift ;;
        --status)    MODE=status; shift ;;
        --reset)     MODE=reset; shift ;;
        -V|--version) echo "restock-watch $VERSION"; exit 0 ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# ---------------------------------------------------------------- defaults --
NAME=""
URL=""
STATUS_REGEX='"status":"([A-Za-z]+)"'
SOLDOUT_VALUES="SoldOut"
ETA_REGEX='"restockEtaAt":"([0-9-]+)"'
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
TIMEOUT=30
STATE_DIR=""
LOG_MAX_BYTES=262144
MAX_FAILURES=5
NOTIFY=""
NOTIFY_SOLDOUT=1
NOTIFY_BLIND=1
MSG_INSTOCK='🛒 {name} is IN STOCK now: {url} (status: {status})'
MSG_SOLDOUT='{name} is sold out again (store says next restock: {eta}). {url}'
MSG_BLIND='⚠️ restock-watch: could not read the status of {name} {n} times in a row (page changed or blocked). I am blind. {url}'
MSG_RECOVERED='restock-watch can read the status of {name} again (currently: {status}).'
MSG_TEST='restock-watch test notification for {name} — this channel works. {url}'
TELEGRAM_TOKEN=""; TELEGRAM_CHAT_ID=""; TELEGRAM_UNRAID_FALLBACK=1
NTFY_URL=""; NTFY_TOKEN=""
GOTIFY_URL=""; GOTIFY_TOKEN=""
PUSHOVER_TOKEN=""; PUSHOVER_USER=""
DISCORD_WEBHOOK=""
SLACK_WEBHOOK=""
WEBHOOK_URL=""
MAIL_TO=""; MAIL_FROM="restock-watch@$(hostname 2>/dev/null || echo localhost)"
NOTIFY_CMD=""

if [ -f "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
else
    echo "config not found: $CONF (copy restock-watch.conf.example and edit it)" >&2
    exit 2
fi

[ -n "$URL" ] || { echo "URL is not set in $CONF" >&2; exit 2; }
[ -n "$NAME" ] || NAME="$URL"

slug=$(printf '%s' "$NAME" | tr -c 'A-Za-z0-9' '-' | tr -s '-' | sed 's/^-//; s/-$//' | cut -c1-40)
[ -n "$STATE_DIR" ] || STATE_DIR="/var/tmp/restock-watch/${slug:-default}"
STATE="$STATE_DIR/state"
FAIL="$STATE_DIR/failures"
LOG="$STATE_DIR/watch.log"
mkdir -p "$STATE_DIR" || { echo "cannot create $STATE_DIR" >&2; exit 2; }

# --------------------------------------------------------------- helpers ----
log() {
    [ "$MODE" = dry ] || printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG"
    [ "$MODE" = run ] || echo "$*"
    return 0
}

rotate_log() {
    [ -f "$LOG" ] || return 0
    [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt "$LOG_MAX_BYTES" ] || return 0
    tail -n 200 "$LOG" > "$LOG.new" && mv "$LOG.new" "$LOG"
}

json_escape() {  # stdin -> JSON string body (no surrounding quotes)
    sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' | sed -e ':a;N;$!ba;s/\n/\\n/g'
}

render() {  # render TEMPLATE with {name} {url} {status} {eta} {n}
    local t="$1"
    t=${t//\{name\}/$NAME}
    t=${t//\{url\}/$URL}
    t=${t//\{status\}/${CUR_STATUS:-?}}
    t=${t//\{eta\}/${CUR_ETA:-unknown}}
    t=${t//\{n\}/$MAX_FAILURES}
    printf '%s' "$t"
}

# ------------------------------------------------------------- notifiers ----
# Every notifier gets: $1 = event (instock|soldout|blind|recovered|test),
# $2 = message text. It must not fail the whole run.

notify_telegram() {
    local token="$TELEGRAM_TOKEN" chat="$TELEGRAM_CHAT_ID" d=/boot/config/plugins/dynamix/telegram
    if [ -z "$token" ] && [ "$TELEGRAM_UNRAID_FALLBACK" = 1 ] && [ -r "$d/token" ]; then
        token=$(cat "$d/token"); chat=$(cat "$d/chatid" 2>/dev/null)
    fi
    [ -n "$token" ] && [ -n "$chat" ] || { log "telegram: no token/chat id"; return 1; }
    curl -fsS -m 20 "https://api.telegram.org/bot$token/sendMessage" \
        --data-urlencode "chat_id=$chat" --data-urlencode "text=$2" \
        --data-urlencode "disable_web_page_preview=true" > /dev/null
}

notify_ntfy() {
    [ -n "$NTFY_URL" ] || { log "ntfy: NTFY_URL not set"; return 1; }
    local prio=default; [ "$1" = instock ] && prio=urgent; [ "$1" = blind ] && prio=high
    local auth=()
    [ -n "$NTFY_TOKEN" ] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    curl -fsS -m 20 -X POST "$NTFY_URL" "${auth[@]}" \
        -H "Title: restock-watch: $NAME" -H "Priority: $prio" -H "Tags: shopping_cart" \
        -H "Click: $URL" --data-binary "$2" > /dev/null
}

notify_gotify() {
    [ -n "$GOTIFY_URL" ] && [ -n "$GOTIFY_TOKEN" ] || { log "gotify: GOTIFY_URL/GOTIFY_TOKEN not set"; return 1; }
    local prio=5; [ "$1" = instock ] && prio=8
    curl -fsS -m 20 -X POST "${GOTIFY_URL%/}/message?token=$GOTIFY_TOKEN" \
        -F "title=restock-watch: $NAME" -F "message=$2" -F "priority=$prio" > /dev/null
}

notify_pushover() {
    [ -n "$PUSHOVER_TOKEN" ] && [ -n "$PUSHOVER_USER" ] || { log "pushover: PUSHOVER_TOKEN/PUSHOVER_USER not set"; return 1; }
    local prio=0; [ "$1" = instock ] && prio=1
    curl -fsS -m 20 https://api.pushover.net/1/messages.json \
        --form-string "token=$PUSHOVER_TOKEN" --form-string "user=$PUSHOVER_USER" \
        --form-string "title=restock-watch: $NAME" --form-string "message=$2" \
        --form-string "url=$URL" --form-string "priority=$prio" > /dev/null
}

notify_discord() {
    [ -n "$DISCORD_WEBHOOK" ] || { log "discord: DISCORD_WEBHOOK not set"; return 1; }
    curl -fsS -m 20 -H 'Content-Type: application/json' \
        -d "{\"content\":\"$(printf '%s' "$2" | json_escape)\"}" "$DISCORD_WEBHOOK" > /dev/null
}

notify_slack() {
    [ -n "$SLACK_WEBHOOK" ] || { log "slack: SLACK_WEBHOOK not set"; return 1; }
    curl -fsS -m 20 -H 'Content-Type: application/json' \
        -d "{\"text\":\"$(printf '%s' "$2" | json_escape)\"}" "$SLACK_WEBHOOK" > /dev/null
}

notify_webhook() {  # generic JSON POST, for Home Assistant, n8n, Node-RED, ...
    [ -n "$WEBHOOK_URL" ] || { log "webhook: WEBHOOK_URL not set"; return 1; }
    curl -fsS -m 20 -H 'Content-Type: application/json' -d "{
  \"event\": \"$1\",
  \"name\": \"$(printf '%s' "$NAME" | json_escape)\",
  \"url\": \"$(printf '%s' "$URL" | json_escape)\",
  \"status\": \"$(printf '%s' "${CUR_STATUS:-}" | json_escape)\",
  \"eta\": \"$(printf '%s' "${CUR_ETA:-}" | json_escape)\",
  \"message\": \"$(printf '%s' "$2" | json_escape)\"
}" "$WEBHOOK_URL" > /dev/null
}

notify_mail() {
    [ -n "$MAIL_TO" ] || { log "mail: MAIL_TO not set"; return 1; }
    if command -v sendmail > /dev/null; then
        printf 'From: %s\nTo: %s\nSubject: restock-watch: %s (%s)\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
            "$MAIL_FROM" "$MAIL_TO" "$NAME" "$1" "$2" | sendmail -t
    elif command -v mail > /dev/null; then
        printf '%s\n' "$2" | mail -s "restock-watch: $NAME ($1)" "$MAIL_TO"
    else
        log "mail: neither sendmail nor mail found"; return 1
    fi
}

notify_unraid() {  # Unraid's own notification system -> every agent you configured there
    local n=/usr/local/emhttp/webGui/scripts/notify sev=normal
    [ -x "$n" ] || { log "unraid: $n not found"; return 1; }
    [ "$1" = instock ] && sev=alert; [ "$1" = blind ] && sev=warning
    "$n" -e "restock-watch" -s "$NAME: $1" -d "$2" -i "$sev" -l "$URL"
}

notify_command() {  # your own script: $1 = message; event details in RW_* env vars
    [ -n "$NOTIFY_CMD" ] || { log "command: NOTIFY_CMD not set"; return 1; }
    RW_EVENT="$1" RW_NAME="$NAME" RW_URL="$URL" RW_STATUS="${CUR_STATUS:-}" RW_ETA="${CUR_ETA:-}" \
        "$NOTIFY_CMD" "$2"
}

notify_stdout() { printf '[%s] %s\n' "$1" "$2"; }

notify() {  # $1 = event, $2 = message
    local ch ok=0 fail=0
    [ -n "$NOTIFY" ] || { log "no NOTIFY channels configured — message dropped: $2"; return 1; }
    for ch in $NOTIFY; do
        if declare -F "notify_$ch" > /dev/null; then
            if "notify_$ch" "$1" "$2"; then ok=$((ok+1)); else fail=$((fail+1)); log "notify via $ch failed"; fi
        else
            log "unknown notifier: $ch"; fail=$((fail+1))
        fi
    done
    log "notified ($1): $ok ok, $fail failed"
    [ "$ok" -gt 0 ]
}

# ---------------------------------------------------------------- modes -----
case "$MODE" in
    status)
        echo "config:   $CONF"
        echo "product:  $NAME"
        echo "url:      $URL"
        echo "state:    $(cat "$STATE" 2>/dev/null || echo '(none yet)')"
        echo "failures: $(cat "$FAIL" 2>/dev/null || echo 0) in a row (alarm at $MAX_FAILURES)"
        echo "notify:   ${NOTIFY:-(none!)}"
        echo "log:      $LOG"; echo
        tail -n 10 "$LOG" 2>/dev/null
        exit 0 ;;
    reset)
        rm -f "$STATE" "$FAIL"; echo "state reset for $NAME"; exit 0 ;;
    test)
        CUR_STATUS="test"; CUR_ETA="unknown"
        notify test "$(render "$MSG_TEST")"; exit $? ;;
esac

# ---------------------------------------------------------------- fetch -----
if command -v flock > /dev/null; then
    exec 9>"$STATE_DIR/lock"
    flock -n 9 || { log "previous run still active, skipping"; exit 0; }
fi
rotate_log

HTML=$(curl -sL -m "$TIMEOUT" -A "$USER_AGENT" "$URL") || HTML=""

# grep finds every match of the pattern, bash's =~ pulls out group 1.
extract() {  # $1 = ERE with one capture group; stdin = HTML
    local m
    grep -oE "$1" | while IFS= read -r m; do
        [[ $m =~ $1 ]] && printf '%s\n' "${BASH_REMATCH[1]:-$m}"
    done
}
STATI=$(printf '%s' "$HTML" | extract "$STATUS_REGEX" | sort -u)
CUR_ETA=$(printf '%s' "$HTML" | extract "$ETA_REGEX" | head -1)
CUR_STATUS=$(printf '%s' "$STATI" | tr '\n' ' ' | sed 's/ $//')

OLD=$(cat "$STATE" 2>/dev/null || echo "")
FAILURES=$(cat "$FAIL" 2>/dev/null || echo 0)

if [ -z "$STATI" ]; then
    FAILURES=$((FAILURES + 1))
    [ "$MODE" = dry ] || echo "$FAILURES" > "$FAIL"
    log "no status found (failure $FAILURES of $MAX_FAILURES, ${#HTML} bytes of HTML)"
    if [ "$FAILURES" -eq "$MAX_FAILURES" ] && [ "$NOTIFY_BLIND" = 1 ] && [ "$MODE" = run ]; then
        notify blind "$(render "$MSG_BLIND")"
    fi
    exit 0
fi

if [ "$FAILURES" -ge "$MAX_FAILURES" ] && [ "$NOTIFY_BLIND" = 1 ] && [ "$MODE" = run ]; then
    notify recovered "$(render "$MSG_RECOVERED")"
fi
[ "$MODE" = dry ] || echo 0 > "$FAIL"

# Anything that is not a known sold-out token means: buyable.
NEW=SOLDOUT
while read -r s; do
    known=0
    for v in $SOLDOUT_VALUES; do [ "$s" = "$v" ] && known=1; done
    [ "$known" = 1 ] || NEW=INSTOCK
done <<< "$STATI"

log "status: $CUR_STATUS -> $NEW (eta: ${CUR_ETA:-unknown}, previous: ${OLD:-none})"

if [ "$MODE" = dry ]; then
    echo "dry run: nothing written, nobody notified"; exit 0
fi

if [ "$NEW" != "$OLD" ]; then
    echo "$NEW" > "$STATE"
    if [ "$NEW" = INSTOCK ]; then
        notify instock "$(render "$MSG_INSTOCK")"
    elif [ -n "$OLD" ] && [ "$NOTIFY_SOLDOUT" = 1 ]; then
        notify soldout "$(render "$MSG_SOLDOUT")"
    fi
fi
exit 0
