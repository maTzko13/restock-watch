# Running restock-watch with systemd (user units)

```sh
install -Dm755 restock-watch.sh ~/.local/bin/restock-watch.sh
install -Dm600 restock-watch.conf.example ~/.config/restock-watch/u5g.conf   # edit it
install -Dm644 examples/systemd/restock-watch@.service ~/.config/systemd/user/
install -Dm644 examples/systemd/restock-watch@.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now restock-watch@u5g.timer
```

The instance name (`u5g`) is the config file name without `.conf`. For a
second product, add another config and enable another timer instance.

Check on it: `restock-watch.sh -c ~/.config/restock-watch/u5g.conf --status`
or `journalctl --user -u restock-watch@u5g.service`.
