# restock-watch

A sold-out product, a shop whose "notify me" e-mail arrives after everyone else has
already ordered, and a machine at home that runs anyway. `restock-watch` polls the
product page every few minutes and pings you the moment the item leaves the
*sold out* state — via Telegram, ntfy, Gotify, Pushover, Discord, Slack, e-mail,
a generic webhook, Unraid's notification system or any command you like.

Bash and `curl`. No Python, no headless browser, no dependencies.

It was written for the [UniFi 5G Backup](https://eu.store.ui.com/eu/en/products/u5g),
which the store had listed for a 23 September restock. The watcher fired on
15 September, eight days early — the order went through while the store's own
notification was still nowhere to be seen. The story is at
[mk-one.de/notizen](https://mk-one.de/notizen/restock-waechter-mit-bordmitteln) (German).

## How it works

1. `curl` fetches the product page with a normal browser user agent.
2. `grep` extracts every match of `STATUS_REGEX` — for shops that render their
   product JSON into the HTML (most do, for speed), that is something like
   `"status":"SoldOut"`.
3. If **any** extracted value is not one of `SOLDOUT_VALUES`, the item is in stock.
   We test for *leaving sold-out* instead of matching "Available", so a shop that
   renames its in-stock label tomorrow does not silently break the watcher.
4. Only **transitions** are reported: sold out → in stock (and, optionally, back).
   Nothing is repeated every three minutes.
5. If the status cannot be extracted `MAX_FAILURES` times in a row, the watcher
   tells you **it has gone blind** — page redesign, bot protection, network gone.
   A watcher that dies silently is worse than none, because you stop checking
   by hand too. When it can see again, it says so.

State, failure counter and log live in `/var/tmp/restock-watch/<name>/` — RAM-backed
on many systems, so a 3-minute cron does not wear out the USB stick an Unraid box
boots from. After a reboot the watcher starts fresh: worst case one duplicate
message, never a missed one.

## Quick start

```sh
git clone https://github.com/maTzko13/restock-watch.git
cd restock-watch
cp restock-watch.conf.example restock-watch.conf
$EDITOR restock-watch.conf          # URL, NAME, NOTIFY and the channel's credentials

./restock-watch.sh --dry-run        # fetch once, show what it extracts, change nothing
./restock-watch.sh --test           # send a test message through every configured channel
crontab -e                          # */3 * * * * /path/to/restock-watch.sh
```

Before pointing it at a new shop, check what the page gives a plain `curl`:

```sh
curl -sL -A "Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0" \
  "https://shop.example/products/thing" | grep -oE '"status":"[A-Za-z]+"' | sort | uniq -c
```

If that prints the stock status, you are done — adjust `STATUS_REGEX` and
`SOLDOUT_VALUES` if the shop uses other words. If it prints nothing, the shop
builds the page in the browser and this tool is the wrong one.

## Usage

```
restock-watch.sh [-c FILE] [--dry-run | --test | --status | --reset]
```

| Option | Effect |
|---|---|
| `-c FILE` | config file (default: `restock-watch.conf` next to the script). One file per product. |
| `--dry-run` | fetch and evaluate once; write nothing, notify nobody |
| `--test` | send a test message through all configured channels |
| `--status` | show current state, failure counter and the last log lines |
| `--reset` | forget the stored state (next run treats the current status as the first one) |

## Notification channels

Set `NOTIFY` to a space-separated list; every channel is tried, one failing
channel does not stop the others.

| Channel | Settings | Notes |
|---|---|---|
| `telegram` | `TELEGRAM_TOKEN`, `TELEGRAM_CHAT_ID` | On Unraid both may stay empty: the Dynamix Telegram agent's credentials are reused. |
| `ntfy` | `NTFY_URL`, `NTFY_TOKEN` (optional) | in-stock is sent with priority *urgent*, the link is attached as click action |
| `gotify` | `GOTIFY_URL`, `GOTIFY_TOKEN` | |
| `pushover` | `PUSHOVER_TOKEN`, `PUSHOVER_USER` | |
| `discord` | `DISCORD_WEBHOOK` | incoming webhook URL |
| `slack` | `SLACK_WEBHOOK` | incoming webhook URL |
| `webhook` | `WEBHOOK_URL` | JSON POST `{event,name,url,status,eta,message}` — Home Assistant, n8n, Node-RED … |
| `mail` | `MAIL_TO`, `MAIL_FROM` | via local `sendmail` or `mail` |
| `unraid` | – | Unraid's `notify` script → every agent configured in the web UI |
| `command` | `NOTIFY_CMD` | your script; message as `$1`, details in `RW_EVENT`, `RW_NAME`, `RW_URL`, `RW_STATUS`, `RW_ETA` |
| `stdout` | – | print it (useful with systemd journal or for testing) |

Events: `instock`, `soldout`, `blind`, `recovered`, `test`. Message texts are
templates (`MSG_INSTOCK` etc.) with `{name} {url} {status} {eta} {n}` placeholders,
so you can localise them in the config — the example file has German ones.

## Running it

- **cron**: `*/3 * * * * /path/to/restock-watch.sh -c /path/to/thing.conf`
- **Unraid**: see [`examples/unraid/`](examples/unraid/) — FAT boot stick, persistent cron, RAM state.
- **systemd**: see [`examples/systemd/`](examples/systemd/) — template timer, one instance per config.

## Be polite

One page every three minutes is 480 requests a day — less than a single human
clicking through a shop, and the kind of traffic web servers exist for. Polling
every few seconds, scraping dozens of pages in parallel or working around bot
protection is not watching, it is a problem. If a shop offers an API or a
notification that actually arrives in time, use that instead. Check the shop's
terms before you point this at it.

## License

MIT — see [LICENSE](LICENSE).
