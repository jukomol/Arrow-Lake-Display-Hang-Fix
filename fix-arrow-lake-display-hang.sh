#!/usr/bin/env bash
#
# fix-arrow-lake-display-hang.sh
#
# Mitigation for a known, unresolved upstream Intel i915 kernel bug that
# causes display hangs / black-screen freezes on laptops with an Intel
# Arrow Lake (or Meteor Lake) iGPU paired with an NVIDIA discrete GPU,
# on Ubuntu 24.04 (kernel 7.0.x).
#
# Upstream bug tracker: https://bugs.launchpad.net/bugs/2150605
#
# WHAT THIS SCRIPT DOES
#   1. Backs up /etc/default/grub before touching it
#   2. Adds i915.enable_psr=0 and i915.enable_dc=0 kernel boot parameters
#      (idempotent -- safe to re-run, won't duplicate params)
#   3. Clears GRUB_CMDLINE_LINUX if it duplicates boot-splash/kernel params
#      (a common source of "my fix isn't sticking" -- see README)
#   4. Warns if /etc/default/grub.d/*.cfg overrides exist, since those are
#      sourced AFTER this file and can silently re-clobber these settings
#   5. Regenerates the GRUB config (update-grub)
#   6. Persistently disables GNOME idle screen-blank (session + GDM login
#      screen) and AC/battery auto-suspend, since those are also triggers
#      for the same underlying PHY bug
#
# WHAT THIS SCRIPT DOES NOT DO
#   It does not fix the underlying kernel bug -- nothing at the OS
#   configuration level can, since the bug lives in Intel's i915 PHY
#   driver code. What this DOES do, based on real-world testing, is
#   convert a hard hang (requiring a forced power-cycle) into a
#   self-recovering stall of roughly 1 minute.
#
# TESTED ON
#   Dell Pro Max 16 Plus -- Intel Arrow Lake -- NVIDIA RTX PRO 5000
#   Blackwell -- Ubuntu 24.04 -- kernel 7.0.0-30-generic
#   (Also reported independently on an HP ZBook Fury G1i with a
#   different NVIDIA RTX PRO Blackwell model -- see README references.)
#
# USAGE
#   sudo ./fix-arrow-lake-display-hang.sh
#
# After it finishes, reboot, then verify with:
#   cat /proc/cmdline
# You should see i915.enable_psr=0 and i915.enable_dc=0 exactly once each.

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "This script needs root privileges (it edits /etc/default/grub and system dconf)."
  echo "Re-run as: sudo $0"
  exit 1
fi

GRUB_FILE="/etc/default/grub"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${GRUB_FILE}.bak.${TIMESTAMP}"

echo "=================================================================="
echo " Arrow Lake / Meteor Lake i915 display-hang mitigation"
echo "=================================================================="
echo

if [[ ! -f "$GRUB_FILE" ]]; then
  echo "ERROR: ${GRUB_FILE} not found. This script assumes a GRUB2-based"
  echo "Ubuntu install. Aborting -- no changes made."
  exit 1
fi

# --- Informational hardware check (never blocks execution) ---
echo "-- Checking hardware signature (informational only) --"
if command -v lspci >/dev/null 2>&1; then
  lspci -nn 2>/dev/null | grep -iE "VGA|3D controller" || true
fi
if dmesg 2>/dev/null | grep -qiE "meteorlake|arrow.?lake"; then
  echo "Detected Meteor Lake / Arrow Lake display engine in dmesg -- this fix likely applies to you."
else
  echo "Could not confirm Meteor Lake/Arrow Lake from the current dmesg buffer"
  echo "(it may have scrolled past on a machine that's been up a while)."
  echo "This script is safe to apply regardless, but the underlying bug is"
  echo "specific to that Intel display generation."
fi
echo

# --- Step 1: back up the grub file ---
echo "-- Backing up ${GRUB_FILE} -> ${BACKUP_FILE} --"
cp "$GRUB_FILE" "$BACKUP_FILE"
echo "Backup saved. To roll back manually: sudo cp ${BACKUP_FILE} ${GRUB_FILE} && sudo update-grub"
echo

# --- Step 2: add kernel parameters to GRUB_CMDLINE_LINUX_DEFAULT ---
echo "-- Updating GRUB_CMDLINE_LINUX_DEFAULT --"
if ! grep -q '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE"; then
  echo 'GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.enable_psr=0 i915.enable_dc=0"' >> "$GRUB_FILE"
  echo "Added new GRUB_CMDLINE_LINUX_DEFAULT line."
else
  EXISTING_VALUE=$(sed -n 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/\1/p' "$GRUB_FILE")
  NEW_VALUE="$EXISTING_VALUE"
  for PARAM in "i915.enable_psr=0" "i915.enable_dc=0"; do
    if [[ "$NEW_VALUE" == *"$PARAM"* ]]; then
      echo "  '$PARAM' already present, skipping."
    else
      NEW_VALUE="$NEW_VALUE $PARAM"
    fi
  done
  grep -v '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" > "${GRUB_FILE}.tmp"
  echo "GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_VALUE}\"" >> "${GRUB_FILE}.tmp"
  mv "${GRUB_FILE}.tmp" "$GRUB_FILE"
  echo "Updated: GRUB_CMDLINE_LINUX_DEFAULT=\"${NEW_VALUE}\""
fi
echo

# --- Step 3: clear GRUB_CMDLINE_LINUX if it duplicates boot params ---
# GRUB_CMDLINE_LINUX applies to EVERY boot entry (including recovery mode)
# and gets concatenated in front of GRUB_CMDLINE_LINUX_DEFAULT. If it
# already contains "quiet splash" or leftover i915.* flags from a manual
# edit, you end up with duplicated parameters on every boot.
echo "-- Checking GRUB_CMDLINE_LINUX for accidental duplication --"
CURRENT_LINUX=$(sed -n 's/^GRUB_CMDLINE_LINUX="\(.*\)"$/\1/p' "$GRUB_FILE")
if [[ "$CURRENT_LINUX" == *"quiet splash"* || "$CURRENT_LINUX" == *"i915."* ]]; then
  echo "Found boot-splash or i915.* parameters inside GRUB_CMDLINE_LINUX --"
  echo "this is almost always accidental and causes duplicated kernel params."
  echo "  Old value: \"${CURRENT_LINUX}\""
  grep -v '^GRUB_CMDLINE_LINUX=' "$GRUB_FILE" > "${GRUB_FILE}.tmp"
  echo 'GRUB_CMDLINE_LINUX=""' >> "${GRUB_FILE}.tmp"
  mv "${GRUB_FILE}.tmp" "$GRUB_FILE"
  echo "Cleared GRUB_CMDLINE_LINUX."
else
  echo "GRUB_CMDLINE_LINUX looks fine, leaving it as-is."
fi
echo

# --- Step 4: warn about grub.d overrides ---
echo "-- Checking for /etc/default/grub.d/ overrides --"
if ls /etc/default/grub.d/*.cfg >/dev/null 2>&1; then
  echo "WARNING: found override file(s) in /etc/default/grub.d/. These are"
  echo "sourced AFTER this script's changes and can silently re-clobber them"
  echo "every time 'update-grub' runs:"
  grep -l "GRUB_CMDLINE" /etc/default/grub.d/*.cfg 2>/dev/null || echo "  (none of them mention GRUB_CMDLINE directly, but review anyway)"
  echo "If your kernel parameters don't stick after rebooting, check these files."
else
  echo "No overrides found in /etc/default/grub.d/."
fi
echo

# --- Step 5: regenerate grub config ---
echo "-- Running update-grub --"
update-grub
echo

# --- Step 6: persistently disable idle screen-blank and auto-suspend ---
# This doesn't touch the periodic DP link-check that can also trigger the
# bug on its own timer, but it removes two other common triggers.
echo "-- Disabling GNOME idle screen-blank and AC/battery auto-suspend (persistent) --"
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/00-no-suspend <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
EOF

mkdir -p /etc/dconf/profile
cat > /etc/dconf/profile/gdm <<'EOF'
user-db:user
system-db:gdm
EOF

mkdir -p /etc/dconf/db/gdm.d
cat > /etc/dconf/db/gdm.d/00-no-blank <<'EOF'
[org/gnome/desktop/session]
idle-delay=uint32 0
EOF

dconf update
echo "Done."
echo

echo "=================================================================="
echo " All changes applied. REBOOT NOW, then verify with:"
echo
echo "   cat /proc/cmdline"
echo
echo " You should see i915.enable_psr=0 and i915.enable_dc=0, each"
echo " appearing exactly once."
echo
echo " This is a MITIGATION for an open upstream bug, not a permanent"
echo " fix. If a hang still happens, a short press of the power button"
echo " (which triggers suspend, then resume) has a good chance of"
echo " recovering the display without a forced power-cycle."
echo
echo " Track the upstream bug: https://bugs.launchpad.net/bugs/2150605"
echo "=================================================================="
