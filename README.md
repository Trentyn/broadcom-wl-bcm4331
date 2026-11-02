# Broadcom BCM4331 wl driver for Linux

Broadcom's `wl` driver patched for current Ubuntu 24.04 HWE kernels (7.x as of now) and Fedora.
Tested on a MacBook Pro mid-2012 (BCM4331) with Ubuntu and with Fedora 44 (kernel 7.2).

## Install

```bash
curl -fsSL https://dl.psibla.de/broadcom | sh
```

Or from a clone:

```bash
git clone https://github.com/Trentyn/broadcom-wl-bcm4331.git
cd broadcom-wl-bcm4331
sudo bash install.sh
```

The installer builds the module with DKMS (rebuilt on kernel updates), blacklists the conflicting Broadcom drivers, loads `wl`, disables Wi-Fi power saving (NetworkManager and TLP) and makes NetworkManager use the card's real MAC address.

Reboot after the first install if `wl` has not attached to the card. Do not bind it by hand through sysfs: that has caused a kernel panic.

Options: `REF=<branch|tag|SHA>` for the one-liner, `KERNEL_SCOPE=running` to build only for the running kernel.

## Notes

- **Dual-band networks.** A network using one name on 2.4 and 5 GHz can cause an endless reconnect loop on this card. Lock its profile to 2.4 GHz: `nmcli connection modify "SSID" wifi.band bg`.
- **Real MAC address.** With a cloned MAC the WPA handshake never completes, and NetworkManager reports it as a wrong password. Networks therefore see the card's real address.
- **objtool.** The Broadcom blob fails objtool, so the `Makefile` runs objtool on the open wrapper code and links the blob in afterwards.
- **6.x kernels** still build but are not supported.
- **Fedora** only keeps the newest `kernel-devel` in its repos, so update and reboot into the newest kernel before installing. Image-based variants (Silverblue, Kinoite) are not supported. Fedora kernels enable IBT and the blob is not built for it, so `wl` may crash on CPUs that support IBT (the tested i5-3210M does not).

Check the build for all installed kernels and the running driver with `./verify.sh`.

## License

Mixed: the Broadcom blob is proprietary (`lib/LICENSE.txt`), the driver sources keep Broadcom's ISC-style license, the scripts are ISC. See [LICENSE](LICENSE).
