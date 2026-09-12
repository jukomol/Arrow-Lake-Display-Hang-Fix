# Full Diagnosis: Display Hangs on Wake (Intel Arrow Lake + NVIDIA Blackwell, Ubuntu 24.04)

> Looking for the quick fix? See the [README](./README.md#quick-start) for the one-command version. This document covers the full investigation, the driver-level root cause, and manual steps for anyone who wants to understand or verify the mitigation before running it.

## Symptoms

- Screen goes black and the system stops responding after sitting idle for a while.
- Happens especially (but not only) with an external monitor connected.
- Also happens after locking the screen (`Super+L`) and leaving it idle.
- Requires a hard power-cycle to recover (before the mitigation below).
- `nvidia-smi` and the NVIDIA driver otherwise work fine — this is **not** an NVIDIA GPU or driver problem.

## What it's *not*

Before landing on the real cause, several reasonable-sounding theories were ruled out:

- **Wrong NVIDIA driver variant.** NVIDIA Blackwell GPUs require the open-kernel-module driver (e.g. `nvidia-driver-580-open`). Installing the closed/proprietary variant isn't supported at all on this hardware. Worth double-checking with `dpkg -l | grep nvidia-driver`, but this was already correct in our case.
- **The NVIDIA driver itself.** Confirmed in the upstream bug report (see [References](#references)): `nvidia-suspend.service` and `nvidia-resume.service` complete cleanly every time. The NVIDIA GPU is not involved in the failure.
- **systemd-logind auto-suspend.** `IdleAction` was unset (defaults to `ignore`) — logind wasn't forcing suspend on idle.
- **GNOME idle/blank settings alone.** These reduce how often you *hit* the bug, but don't eliminate it — see below.

## Root cause

The actual bug lives in the Intel **i915** driver, specifically in how it talks to the internal display PHY ("CX0 PHY") on Arrow Lake/Meteor Lake silicon.

The display controller doesn't program the PHY directly — it communicates over an internal **message bus**: the driver writes a request into a control register, sets a pending flag, and polls a status register waiting for the PHY to acknowledge within a short, fixed timeout. Every symptom below is a different stage of that same handshake timing out:

```
Failed to bring PHY A to idle.
PHY A Read/Write 0c70 failed after N retries.
Timeout waiting for DDI BUF A to get active.
Timed out waiting for DP idle patterns.
PHY A failed to request refclk
PHY A failed to change powerdown state
[CRTC:150:pipe A] flip_done timed out
```

...followed by a kernel WARNING:

```
WARNING: ... pipe state doesn't match!
```

That last WARNING is a **pure diagnostic assertion**, not the cause — `verify_crtc_state()` in the i915 source just re-reads hardware state after a commit and compares it against what software expected, then WARNs on mismatch. The real failure already happened upstream, in the PHY handshake.

One detail worth calling out from the driver source (`intel_cx0_phy.c`): when the bus-reset handshake times out, the function logs the error and **returns immediately without clearing the PHY's response-ready/error flags first**. That's a plausible reason a single missed acknowledgment can cascade into a longer retry storm instead of the driver cleanly recovering on the first miss.

### Two different triggers, same underlying bug

1. **Suspend/resume (s2idle).** The PHY parks at a low idle clock while suspended; on resume, the next display commit tries to relock it at full rate and the handshake above can fail.
2. **A periodic internal DP link health-check** (`intel_dp_link_check()` → `intel_dp_retrain_link()`) that the i915 driver runs on its own schedule, independent of any suspend or blanking setting. This means disabling idle-blank and auto-suspend reduces exposure but does **not** fully eliminate the trigger — there's no user-facing toggle for this internal check.

### Confirmed active, unresolved upstream

This is tracked as [Ubuntu Launchpad bug #2150605](https://bugs.launchpad.net/bugs/2150605), affecting Arrow Lake-S / Meteor Lake display hardware. As of this writing it has not landed a fix.

## How this was diagnosed

In case you're chasing a similar issue on different hardware, this is the process that got us here:

1. **Confirm driver variant first.** `dpkg -l | grep nvidia-driver` — must show an `-open` package for Blackwell GPUs.
2. **Enable persistent journal logging** so a hard crash doesn't lose the final log entries:
   ```bash
   sudo mkdir -p /var/log/journal
   sudo systemd-tempfiles --create --prefix /var/log/journal
   sudo systemctl restart systemd-journald
   ```
3. **Correlate the actual hang to the correct boot**, not just `-1` blindly — `journalctl --list-boots --no-pager` and match timestamps to when you actually experienced the freeze.
4. **Capture kernel + full journal from that boot:**
   ```bash
   journalctl -b <BOOT_ID> --no-pager > hang.txt
   journalctl -b <BOOT_ID> -k --no-pager >> hang.txt
   ```
5. **Search the log for the failure signature** rather than assuming — in our case, `grep -iE "i915|nvidia|PHY|DPLL|flip"` surfaced the exact error cascade above.
6. **Match the signature against known upstream reports** — searching the exact error strings (`"Failed to bring PHY A to idle"`, `verify_crtc_state`) turned up the Launchpad bug directly.
7. **Read the actual driver source** to confirm the mechanism rather than guessing — the Linux kernel source for `drivers/gpu/drm/i915/display/` is public and readable even without kernel-dev experience; matching real error strings to real function names removes the guesswork.

## The fix (mitigation)

Add two kernel boot parameters. Both matter — testing (ours and the upstream report) showed `enable_psr=0` alone was not confirmed to prevent a hard hang on a long idle period; the combination that was actually shown to convert a hard hang into a slow, self-recovering wake is **both together**.

### Manual steps

1. Edit `/etc/default/grub`:
   ```bash
   sudo nano /etc/default/grub
   ```
2. Set:
   ```
   GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.enable_psr=0 i915.enable_dc=0"
   ```
3. **Check `GRUB_CMDLINE_LINUX` too** (the other, normally-blank variable) — a stray copy of `quiet splash` or old params left in there applies to *every* boot entry and gets concatenated in front of the line above, causing silent duplication. It should be:
   ```
   GRUB_CMDLINE_LINUX=""
   ```
4. **Check for overrides in `/etc/default/grub.d/*.cfg`** — Ubuntu 24.04 sources these after the main file, and a vendor/OEM installer can silently re-clobber your edit on every `update-grub`.
5. Apply and reboot:
   ```bash
   sudo update-grub
   sudo reboot
   ```
6. Verify:
   ```bash
   cat /proc/cmdline
   ```
   You should see `i915.enable_psr=0 i915.enable_dc=0` exactly once each.

Flags tested and found **not** to add further benefit on top of the two above: `i915.enable_fbc=0`. Also tested and **not recommended**: forcing the newer `xe` driver via `xe.force_probe=` — this trades the hang for a different bug (GPU engine reset storm, eventual wedge).

### Automated

[`fix-arrow-lake-display-hang.sh`](./fix-arrow-lake-display-hang.sh) does all of the above, safely:
- Backs up `/etc/default/grub` before editing
- Adds the two kernel parameters (idempotent — safe to re-run)
- Detects and clears an accidentally-duplicated `GRUB_CMDLINE_LINUX`
- Warns if `/etc/default/grub.d/` overrides exist
- Runs `update-grub`
- Also persistently disables GNOME idle screen-blank and AC/battery auto-suspend, as a belt-and-suspenders reduction in trigger frequency

## If it still hangs completely

A short press of the power button — which triggers suspend, then immediately resume — has, in practice, a real chance of un-wedging the display without needing a forced power-cycle. Worth trying before reaching for a hard reboot.

## Additional hardening (optional, reduces frequency but not root cause)

Disable idle screen-blank for your session and for the GDM login screen (both share this bug's exposure, since GDM has its own idle timer):

```bash
gsettings set org.gnome.desktop.session idle-delay 0
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing'
gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing'
sudo -Hu gdm dbus-run-session -- gsettings set org.gnome.desktop.session idle-delay 0
```

These are session-level settings and can silently reset — for a persistent fix, use the dconf profile approach the script sets up automatically (see script source).

## A red herring worth knowing about: `igc` PTM timeout

You may also see this in your logs around a wake event:

```
igc 0000:XX:00.0 enpXsX: timeout reading IGC_PTM_STAT register
```

This is unrelated. `igc` is the driver for Intel I225/I226 Ethernet controllers; `IGC_PTM_STAT` is a status register for PCIe Precision Time Measurement (hardware timestamping, used for PTP/TSN — not ordinary networking). It's a separate, well-known area of upstream driver churn and does not affect basic network connectivity. Don't spend time chasing it as part of this bug.

## References

- [Ubuntu Launchpad bug #2150605](https://bugs.launchpad.net/bugs/2150605) — the primary tracker for this issue on Arrow Lake-S / Meteor Lake.
- [Detailed investigation thread](https://www.mail-archive.com/ubuntu-bugs@lists.ubuntu.com/msg6272941.html) — includes the testing table showing which kernel flag combinations converted a hard hang into a slow recovery, and confirms the NVIDIA dGPU is not implicated.
- Linux kernel source: `drivers/gpu/drm/i915/display/intel_cx0_phy.c`, `intel_modeset_verify.c`, `intel_dp_link_training.c` — read directly to confirm the mechanism described above.

## Disclaimer

This is a community-sourced mitigation for an **open, unresolved upstream kernel bug**. It reduces failure severity; it does not fix the root cause. Back up your GRUB configuration before making changes (the script does this automatically), and expect to revisit this once a real fix lands in a future kernel release.
