# Troubleshooting

## Where are the logs?

All scripts write logs to:

```bash
ls -1 /var/log/gns3-bare-metal/
```

If you are asking for support, include the relevant log file(s).


## SSH dropped after Step 01 or Step 04
- This is usually a Netplan change interrupting the interface.
- Use console access and roll back to the last backup:

```bash
ls -1 /etc/netplan/01-static-ip.yaml.bak.*
sudo cp -a /etc/netplan/01-static-ip.yaml.bak.<timestamp> /etc/netplan/01-static-ip.yaml
sudo netplan apply
```

## “uBridge is not available” in GNS3
- Verify `ubridge` is installed and the `gns3` user can run it:

```bash
command -v ubridge
sudo -u gns3 -H ubridge -v
id gns3
```

- Ensure `gns3` is in the `ubridge` group and reboot.

## Docker permission denied for gns3 user
- Reboot after Step 02, or log out and log back in.
- Confirm group:

```bash
id -nG gns3 | tr ' ' '\n' | grep -x docker
```

## Cloud node cannot bind to tap0/tap1
- Verify TAPs exist and are up:

```bash
ip -br link show tap0 tap1
```

- Verify the systemd service:

```bash
systemctl status gns3-taps.service --no-pager
```

## No space left on device (root volume full)
If your root filesystem is small and you used Ubuntu LVM defaults, run:

```bash
sudo bash scripts/05-expand-root-lvm-ubuntu.sh
```

If it exits saying the LV path is missing, your install is not using Ubuntu’s default LVM path — expand storage using your disk layout tools.


## Host readiness report

Generate a single health report:

```bash
sudo bash scripts/07-verify-host.sh
```

If NOT READY, include the verify output and relevant log files in `/var/log/gns3-bare-metal/`.


## TAP service fails (gns3-taps.service)

If `gns3-taps.service` fails with errors mentioning `2>/dev/null` or `garbage`, ensure your unit file does not contain shell redirection in `ExecStart*` lines. systemd does not run these commands through a shell.

Fix by using systemd’s error-tolerant prefix `-`:

- `ExecStartPre=-/usr/sbin/ip link del tap0`

Then reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart gns3-taps
```
