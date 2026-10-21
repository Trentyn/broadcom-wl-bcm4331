# Broadcom BCM4331 wl driver for Linux 7.x

Broadcom's `wl` driver patched for Ubuntu 24.04 HWE 7.0 kernels.
Tested on a MacBook Pro mid-2012 (BCM4331).

## Install

```bash
curl -fsSL https://dl.psibla.de/broadcom | sh
```

Or from a clone:

```bash
git clone https://github.com/Trentyn/broadcom-wl-linux6.git
cd broadcom-wl-linux6
sudo bash install.sh
```

The installer builds the module with DKMS (rebuilt on kernel updates), blacklists the conflicting Broadcom drivers, loads `wl` and disables Wi-Fi power saving (NetworkManager and TLP).

Options: `REF=<branch|tag|SHA>` for the one-liner, `KERNEL_SCOPE=running` to build only for the running kernel.

## Notes

- **2.4 GHz only.** 5 GHz is not registered: on this card a dual-band SSID causes an endless reconnect loop.
- **objtool.** The Broadcom blob fails objtool, so the `Makefile` runs objtool on the open wrapper code and links the blob in afterwards.
- **6.x kernels** still build but are not supported.

Check the build for all installed kernels and the running driver with `./verify.sh`.
