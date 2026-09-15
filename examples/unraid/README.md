# Running restock-watch on Unraid

```sh
mkdir -p /boot/config/restock-watch
cp restock-watch.sh /boot/config/restock-watch/
cp restock-watch.conf.example /boot/config/restock-watch/u5g.conf   # edit it
cp examples/unraid/restock-watch.cron /boot/config/plugins/dynamix/
update_cron
```

Three Unraid specifics, all handled by the files above:

- `/boot` is a FAT file system without execute bits, so the cron line calls
  `bash <path>` instead of executing the script directly.
- Cron entries under `/boot/config/plugins/dynamix/*.cron` survive a reboot and
  are merged into `/etc/cron.d/root` by `update_cron` — they do **not** show up
  in `crontab -l`.
- State and log default to `/var/tmp/restock-watch/…`, which lives in RAM: a run
  every three minutes would otherwise write to the USB stick Unraid boots from.

Notifications: leave `TELEGRAM_TOKEN`/`TELEGRAM_CHAT_ID` empty and `NOTIFY="telegram"`
reuses the Telegram agent you configured in *Settings → Notifications*. Or use
`NOTIFY="unraid"` to route through Unraid's own notification system and reach
every agent configured there.

Removing it again: delete the `.cron` file, run `update_cron`, remove the folder.
