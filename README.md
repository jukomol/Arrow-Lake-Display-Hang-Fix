# Arrow Lake + NVIDIA Blackwell Laptop Display Hang Fix (Ubuntu 24.04)

Laptops with an **Intel Arrow Lake (or Meteor Lake) iGPU** paired with an **NVIDIA discrete GPU** on **Ubuntu 24.04** can hit an open upstream kernel bug that causes the screen to go black and the whole machine to become unresponsive after a period of inactivity, screen lock, or suspend.

This repo documents the root cause and provides a script that mitigates it — turning a hard hang (forced power-cycle) into a self-recovering ~1 minute stall.

**Tested on:** Dell Pro Max 16 Plus — Intel Arrow Lake — NVIDIA RTX PRO 5000 Blackwell — Ubuntu 24.04 — kernel `7.0.0-30-generic`. Also reported independently on an HP ZBook Fury G1i with a different RTX PRO Blackwell model — see [TROUBLESHOOTING.md](./TROUBLESHOOTING.md#references).

## Is this your bug?

- Screen goes black / system freezes after sitting idle for a while
- Happens especially with an external monitor connected, or after locking the screen (`Super+L`)
- Requires a hard power-cycle to recover
- `nvidia-smi` and the NVIDIA driver otherwise work fine — this is **not** an NVIDIA problem

If that matches, you're very likely hitting [Ubuntu Launchpad bug #2150605](https://bugs.launchpad.net/bugs/2150605) (Intel i915 display PHY, Arrow Lake-S / Meteor Lake).

## Quick start

```bash
git clone <this-repo-url>
cd <this-repo>
sudo ./fix-arrow-lake-display-hang.sh
sudo reboot
```

After reboot, verify it took effect:

```bash
cat /proc/cmdline
```

You should see `i915.enable_psr=0` and `i915.enable_dc=0`, each appearing exactly once.

**This is a mitigation, not a fix** — the underlying kernel bug is still open upstream. If you still hit a full hang, a short press of the power button (suspend, then resume) has a good chance of recovering the display without a forced reboot.

## Files

| File | Purpose |
|---|---|
| [`fix-arrow-lake-display-hang.sh`](./fix-arrow-lake-display-hang.sh) | Automated script: applies the kernel-parameter mitigation and reduces trigger frequency |
| [`TROUBLESHOOTING.md`](./TROUBLESHOOTING.md) | Full root-cause investigation: how this was diagnosed, the driver-level mechanism, manual fix steps, and known red herrings |

## Contributing

If you hit this on different hardware:
1. Comment on [bug #2150605](https://bugs.launchpad.net/bugs/2150605) with your laptop model, GPU, and kernel version — cross-OEM confirmation helps get it prioritized upstream.
2. Open a PR here with your data point (hardware model, kernel version, whether the mitigation worked).

## Disclaimer

This mitigates a known, unresolved upstream kernel bug — it does not fix the root cause. Back up your GRUB configuration before making changes (the script does this automatically), and expect to revisit this once a real fix lands in a future kernel release.
