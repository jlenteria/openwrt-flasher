# OpenWrt Flasher

A desktop app (macOS, Windows, Linux) for flashing and recovering OpenWrt boards.

## Flash

Upgrade a running OpenWrt device over SSH with `sysupgrade`:

- Finds the router on the LAN, or takes an address you type in.
- Reads the board name over SSH and checks that the image names this board.
- Checks free RAM in `/tmp`, uploads over SFTP, verifies SHA-256, runs `sysupgrade -T`.
- Optionally downloads a configuration backup first.
- Waits for the reboot and confirms the board came back.

A fresh OpenWrt install has no root password: leave the password empty.

## Recovery

Unbrick a board, or install OpenWrt for the first time, with a serial console and the built-in servers:

- **U-Boot TFTP**: stop autoboot, `tftpboot` an initramfs image from the built-in TFTP server and boot it from RAM.
- **Vendor TFTP recovery**: serve the exact file name a bootloader requests when the reset button is held at power-on. Every request is logged.
- **Failsafe mode**: enter OpenWrt failsafe to reset the password or restore defaults.
- Then install permanently, either from the Flash tab or by serving the sysupgrade image over the built-in HTTP server.

Board-specific details (UART pinout, bootloader key, load address, recovery file name) are in the
[OpenWrt Table of Hardware](https://openwrt.org/toh/start).

### Notes

- The TFTP server uses UDP port 69. On Linux this needs root or `cap_net_bind_service`.
- Allow the app through the firewall for UDP 69 and TCP 8080.

## Development

```sh
make get-deps
make run-all
make test
```

### Installing on Linux

```sh
make build-linux
make install-linux                          # per user, into ~/.local
sudo make install-linux PREFIX=/usr/local   # system-wide
```

This installs the app, its icon and `linux/packaging/com.bling.openwrtFlasher.desktop`, so it shows up in
the application menu and dock. `make uninstall-linux` (with the same `PREFIX`) removes it.
