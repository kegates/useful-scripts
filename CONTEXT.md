# Project context

## Goal

A repo of scripts usable across all of the user's devices: Windows 10/11
laptops/desktops, Raspberry Pi 5s (Raspberry Pi OS), and Red Pitaya boards
(Red Pitaya OS). Pull the repo on a new/reimaged machine and the scripts
just work, called from the command line, without per-OS relearning. On
Windows the user usually has WSL available too, but is fine running things
via native PowerShell when a script needs real access to the Windows host
(see the WSL note below — it's a hard requirement, not a preference).

## Scripts so far

### `network-profiles/` (first script, in progress)

Switches a machine's ethernet and/or wifi between DHCP and a static IP by
applying a named "profile" (JSON file), leaving whichever interface isn't
mentioned in the profile untouched. Full design rationale and usage is in
`network-profiles/README.md` — this file only tracks the *why* behind
decisions and what's actually been verified to work, so a future session
doesn't have to re-derive it.

**Key design decisions:**

- Profile files are named `profiles/<scenario>.<hostname>.json` — one file
  per device per scenario (chosen over a hostname-keyed map in a single
  file, or a shared-profile-plus-local-override split). The script resolves
  its own hostname at runtime to pick the right file.
- Ethernet/wifi interfaces are auto-detected by role (physical media type on
  Windows, presence of `/sys/class/net/*/wireless` on Linux), not by name —
  adapter names differ per machine and this avoids needing per-device
  overrides for that.
- Linux backend is auto-detected, not assumed: **Raspberry Pi OS Bookworm+**
  defaults to NetworkManager (`nmcli`); **Red Pitaya OS** uses
  `systemd-networkd` directly (confirmed via Red Pitaya's own docs — this
  was *not* a safe assumption, an earlier draft wrongly assumed nmcli
  everywhere). The script picks a backend by checking which service is
  active, not by OS-sniffing.
- For the networkd backend, config is written to
  `/etc/systemd/network/00-profile-<role>.network` — the `00-` prefix is
  load-bearing: systemd-networkd applies only the *first* matching
  `.network` file per interface in lexical order, so this is what makes our
  config win over Red Pitaya's own default `wired.network`/`wireless.network`.
- Both scripts print a BEFORE snapshot (and AFTER + verification on a real
  run, not just `--dry-run`) of link state/address/gateway/DNS, plus
  pre-checks (gateway not in the target subnet, invalid DNS entries,
  ambiguous multi-adapter matches, APIPA addresses). This was requested
  explicitly after manually walking through what to check in chat — the
  user wants the scripts to self-verify, not just act.
- `linux/apply-profile.sh` refuses to run under WSL (detects via
  `/proc/version` / `$WSL_DISTRO_NAME`) and points to the PowerShell script
  instead. WSL has its own virtual network stack and cannot touch a Windows
  host's physical NICs — there is no way to make this work, not just an
  unimplemented feature.
- Reverse scenario (wired internet + wifi as the direct SSH link) is
  **deliberately deferred**. Unlike the ethernet case, two wifi clients
  can't just static-IP their way into talking to each other — one side
  needs to host an access point. Flagged as future work, not attempted.

**Bugs found and fixed during testing:**

- `$ErrorActionPreference = "Stop"` at the top of `Apply-Profile.ps1` made
  every `Write-Error` call terminate the script immediately, which silently
  skipped intentional follow-up code (e.g. listing available profile files
  when the requested one wasn't found). Fixed by adding
  `-ErrorAction Continue` to the intentional/handled `Write-Error` calls and
  making the exit explicit right after.
- Example profile files originally used placeholder hostnames
  (`laptop`/`raspberrypi`/`redpitaya`). Renamed the laptop ones to the
  user's real hostname (`kevin-laptop`) once confirmed, so a fresh copy of
  the repo works without a manual rename.

**Testing status (as of last session):**

- Windows: `-DryRun` confirmed working on the user's laptop (`kevin-laptop`)
  after fixing the above bug. Real (non-dry-run) apply has **not** been
  tested yet.
- The laptop has no built-in ethernet adapter, so a USB-ethernet dongle was
  plugged in (2026-07-25) to exercise the ethernet role in `-DryRun`, no
  cable connected to anything else. Result: adapter-role detection correctly
  picked up the dongle as `ethernet`, correctly reported `Disconnected` +
  an APIPA (169.254.x.x) address with the "DHCP may not be handing out a
  lease" warning, correctly noted config can still be staged on a down
  link, and the dry-run static values (`10.10.10.1/24`, no gateway/dns)
  matched `profiles/ssh-link.kevin-laptop.json` exactly. All expected,
  no bugs found. Still untested: a real (non-dry-run) apply, and the
  AFTER/verification block on a link that's actually Up — needs the dongle
  plugged into the Raspberry Pi once it's set up (not done yet as of this
  session).
- Linux side (`apply-profile.sh`, both nmcli and systemd-networkd branches)
  has **not** been tested on real hardware yet — no jq/nmcli available in
  the dev sandbox used to write it. Needs verification on an actual
  Raspberry Pi and, eventually, a Red Pitaya.
- Windows execution policy: on the user's machine, `Unblock-File` alone
  (recursively over the copied folder) was sufficient to allow the script
  to run — `Set-ExecutionPolicy` was tried but reverted back to
  `Undefined` for CurrentUser afterward and the script still worked. So
  `Unblock-File` is the thing to check first on any machine where files
  arrived via copy/zip/OneDrive rather than `git clone`.

**Not yet built:** everything else. This is the first of what's meant to be
a growing set of cross-device scripts in this repo.
