# Broadcom BCM4331 wl driver for Linux kernel 7.x

Broadcom's `wl` hybrid wireless driver patched to build on modern Linux kernels. The target is the Ubuntu 24.04 HWE 7.0 kernel line.

**Hardware:** MacBook Pro mid-2012, Broadcom BCM4331 802.11a/b/g/n

## Install

One-liner (clones the latest `main` into `/tmp/broadcom-wl-linux6` and runs `install.sh`):

```bash
curl -fsSL https://dl.psibla.de/broadcom | sh
```

Set `REF=<branch, tag or full commit SHA>` to install a specific version. Or manually:

```bash
git clone https://github.com/Trentyn/broadcom-wl-linux6.git
cd broadcom-wl-linux6
sudo bash install.sh
```

The script installs all dependencies, builds via DKMS (auto-rebuilds on kernel updates), blacklists conflicting drivers, loads the module, and runs `fix-powersave.sh` to disable WiFi power management (prevents disconnects after long uptime).

The installer is intentionally conservative:

- it only calls `apt-get install` when required build dependencies are actually missing
- it refreshes `/usr/src/broadcom-wl-6.30.223.271` from the checked-out tree (sources only, no git metadata or build output) before registering DKMS
- it builds/installs the module for every installed kernel that already has headers under `/lib/modules/*/build`; a failure on a non-running kernel is reported as a warning, a failure on the running kernel aborts the install
- it runs a post-install smoke check to make sure `wl` is installed, loadable, and exposes a wireless interface

This matters on systems where a broken DKMS tree has already left `dpkg` or a kernel upgrade half-configured: the custom source is synced first, and future DKMS rebuilds use the same source and flags.

## Support policy

Supported: Linux 7.x, specifically the Ubuntu 24.04 HWE 7.0 kernels (the running kernel plus the next one you are upgrading into).

- 6.x kernels are not a support target. The `LINUX_VERSION_CODE` guards for 6.x are kept because the same guards select the new APIs on 7.x; 6.14 and 6.17 still build, but they are not tested at runtime.
- The installer rebuilds for every installed kernel with headers, so the previous 7.x kernel stays usable as a rollback.
- Once the machine runs the new HWE kernel, remove old kernels and their headers normally (`apt purge`); DKMS stops building for them automatically.

If you want a minimal install onto the currently running kernel only, use:

```bash
sudo KERNEL_SCOPE=running bash install.sh
```

To apply the power management fix independently on an already-installed system:

```bash
sudo bash fix-powersave.sh
```

## What was patched for kernel 6.x/7.x

| File | Change |
|---|---|
| `Makefile` | `EXTRA_CFLAGS` → `ccflags-y`; link the open wrapper objects (with `objtool`) first and merge the Broadcom blob in a second link step without `objtool` |
| `src/include/linuxver.h` | Guard removed `net/lib80211.h` include (gone in 6.11+) |
| `src/wl/sys/wl_linux.h` | Replace removed `lib80211`/`ieee80211_tkip` types with `void *` |
| `src/wl/sys/wl_linux.c` | `asm/unaligned.h` → `linux/unaligned.h`, `from_timer` → `container_of`, `del_timer` → `timer_delete`, add `MODULE_DESCRIPTION()` for newer modpost |
| `src/wl/sys/wl_cfg80211_hybrid.c` | Add `radio_idx`/`link_id` params to `set_wiphy_params`, `set_tx_power`, `get_tx_power` (cfg80211 API changes in newer 6.x kernels) |
| `src/wl/sys/wl_linux.c`, `wl_cfg80211_hybrid.c` | Index the `ea[1]` multicast list and `pmkid[1]` PMKSA list from the start of their real buffers, which fixes `UBSAN: array-index-out-of-bounds` in `_wl_set_multicast_list`; the PMKSA debug print no longer reads past the list |
| `fix-powersave.sh` | Also sets `WIFI_PWR_ON_AC/BAT=off` for TLP, which otherwise turns Wi-Fi power saving back on when the laptop runs on battery |

## Kernel 7.0 note

On kernel `7.0.0-28-generic`, the proprietary Broadcom blob inside `lib/wlc_hybrid.o_shipped` trips `objtool` during final module link with:

```text
wl.o: error: objtool: aes_cbc_encrypt_pad+0x4c: unannotated intra-function call
```

That error comes from the shipped binary object rather than the open wrapper code. Ubuntu 7.0 kernels enable `CONFIG_KLP_BUILD`, which makes kbuild run `objtool` once on the linked `wl.o` instead of on each object file, so the blob gets checked too.

An earlier version of this tree disabled `objtool` entirely (`cmd_objtool=`). The module built, but the wrapper code then had no `.return_sites`/`.retpoline_sites` tables, and loading `wl` logged `WARNING: Unpatched return thunk in use. This should not happen!`. The `Makefile` now overrides the multi-object link: `objtool` runs on the open wrapper objects only, and the blob is merged afterwards with a plain `ld -r`. The resulting module has the same imported symbols and CRCs, plus the annotation sections the kernel needs.

## Verification

For repeatable local validation, run:

```bash
./verify.sh
```

That script rebuilds the module against every installed kernel with headers and verifies that the currently running kernel can see a loaded `wl` module and a wireless interface. To limit the build check to the active kernel only:

```bash
KERNEL_SCOPE=running ./verify.sh
```
