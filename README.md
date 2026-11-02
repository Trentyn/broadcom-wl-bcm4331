# Broadcom BCM4331 wl driver for Linux

Broadcom's `wl` driver patched for current Ubuntu 24.04 HWE kernels (7.x as of now) and Fedora.
Tested on a MacBook Pro mid-2012 (BCM4331) with Ubuntu.

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

The installer builds the module with DKMS (rebuilt on kernel updates), blacklists the conflicting Broadcom drivers, loads `wl` and disables Wi-Fi power saving (NetworkManager and TLP).

Options: `REF=<branch|tag|SHA>` for the one-liner, `KERNEL_SCOPE=running` to build only for the running kernel.

## Notes

- **2.4 GHz only.** 5 GHz is not registered: on this card a dual-band SSID causes an endless reconnect loop.
- **objtool.** The Broadcom blob fails objtool, so the `Makefile` runs objtool on the open wrapper code and links the blob in afterwards.
- **6.x kernels** still build but are not supported.
- **Fedora** only keeps the newest `kernel-devel` in its repos, so update and reboot into the newest kernel before installing. Image-based variants (Silverblue, Kinoite) are not supported.

Check the build for all installed kernels and the running driver with `./verify.sh`.

## License

Mixed: the Broadcom blob is proprietary (`lib/LICENSE.txt`), the driver sources keep Broadcom's ISC-style license, the scripts are ISC. See [LICENSE](LICENSE).
