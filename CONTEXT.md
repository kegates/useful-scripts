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

- Profile files are named `profiles/<device>.json` — one file **per
  device profile**, containing all of that profile's scenarios (`home`,
  `ssh-link`, etc.) as top-level keys. (Originally one file per device *per
  scenario*, `profiles/<scenario>.<hostname>.json`; changed 2026-07-27
  because the user wanted all of a device's scenarios in a single file
  rather than scattered across separate files.)
- **2026-07-27 (later same day): dropped hostname auto-detection
  entirely.** The scripts used to resolve `$env:COMPUTERNAME`/`hostname` at
  runtime to pick `profiles/<hostname>.json` automatically. Replaced with
  two explicit CLI args on both scripts — Windows: `-Device`/`-Scenario`;
  Linux: positional `<device> <scenario-name>`. Reason: the user pointed out
  that multiple machines of the same class (every Windows laptop, every Pi)
  will usually want identical settings, so a naming scheme tied to each
  machine's literal hostname doesn't scale — you'd need a new file per
  machine even when the content would be identical. `<device>` is now just
  an arbitrary label the user picks and passes explicitly (e.g.
  `kevin-laptop`, or a shared `raspberrypi`), decoupled from the OS
  hostname. This also incidentally sidesteps ever needing to look up a new
  machine's hostname to get the script running.
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
- `Apply-Profile.ps1`'s "scenario not found" branch (added in the
  2026-07-27 restructure) wrote `"Available scenarios for $hostLower:"` in
  a double-quoted string. PowerShell parses `$var:` as an attempt at a
  drive/scope-qualified variable name (like `$env:PATH`), not "variable
  then literal colon", so this is a **parse-time** error — it would fail on
  any machine, immediately, regardless of hostname. Found 2026-07-27 on a
  second Windows PC running `-DryRun`. Fixed with `${hostLower}:`. Lesson:
  any `"$var:..."` in a PS string needs `${var}:` instead.

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
  matched the `ssh-link` scenario in what was then
  `profiles/ssh-link.kevin-laptop.json` exactly. All expected,
  no bugs found. Still untested: a real (non-dry-run) apply, and the
  AFTER/verification block on a link that's actually Up — needs the dongle
  plugged into the Raspberry Pi once it's set up (not done yet as of this
  session).
- Linux side (`apply-profile.sh`, both nmcli and systemd-networkd branches)
  has **not** been tested on real hardware yet — no jq/nmcli available in
  the dev sandbox used to write it. Needs verification on an actual
  Raspberry Pi and, eventually, a Red Pitaya.
- **2026-07-27 profile-file restructure** (one file per device instead of
  per device+scenario, see design decisions above) touched the
  hostname/scenario lookup logic in both `apply-profile.sh` and
  `Apply-Profile.ps1`. JSON shape was validated with `python3 -m json.tool`
  and the bash script passed `bash -n` (syntax only) — jq still isn't
  available in this dev sandbox, so the actual jq-based lookup path in
  `apply-profile.sh` has **not** been exercised. This restructure introduced
  the `"Available scenarios for $hostLower:"` parse-time bug described
  above, found the same day on a second Windows PC — the Windows `-DryRun`
  path had not actually been re-run against the new file layout until then.
- **2026-07-27 (same day, after the above): CLI args replaced hostname
  auto-detection** (`-Device`/`-Scenario` on Windows, positional
  `<device> <scenario-name>` on Linux — see design decisions above). Re-tested
  same day: `.\Apply-Profile.ps1 -Device kevin-laptop -Scenario ssh-link
  -DryRun` run on the laptop after a `git pull`, this time with the
  USB-ethernet dongle plugged into an actually-running Raspberry Pi (Pi's
  ethernet not yet configured — still on its own defaults). Result: link
  status `Up`, `dhcp: Enabled`, APIPA address `169.254.102.159/16` correctly
  detected and warned on (expected: neither side has a DHCP server on that
  link), dry-run static values (`10.10.10.1/24`, no gateway/dns) matched
  `ssh-link` in `kevin-laptop.json` exactly, wifi correctly left alone. New
  CLI-arg shape confirmed working end-to-end on real hardware. Still
  untested: a real (non-dry-run) apply, and the Pi side of the link is not
  yet configured with a matching static IP (e.g. `10.10.10.2/24`) — needed
  before SSH over this link will actually work, not just the laptop side.
  Linux (`apply-profile.sh`, positional-args shape) still not re-tested with
  the new arg shape at all.
- Windows execution policy: on the user's original machine, `Unblock-File`
  alone (recursively over the copied folder) was sufficient to allow the
  script to run — `Set-ExecutionPolicy` was tried but reverted back to
  `Undefined` for CurrentUser afterward and the script still worked. On a
  **second, new PC being tested** (2026-07-27), `Unblock-File` alone was not
  enough — `Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy
  RemoteSigned` was actually required there. So both are legitimate fixes
  depending on the machine, not just the first one. `Unblock-File` is still
  the thing to try first (non-invasive), but don't assume it alone will be
  enough on every machine. Documented in both the top-level README.md and
  `network-profiles/README.md`.

- **2026-07-27 (same day, after the above): added `-Help`/`--help`.**
  `apply-profile.sh` already had `-h`/`--help`; `Apply-Profile.ps1` did not,
  so `-Device`/`-Scenario` were changed from `Mandatory = $true` to plain
  positional params, a `Show-Usage` function was added (mirrors the bash
  script's `usage()`: device/scenario semantics, options, examples), and a
  `-Help` switch was added that prints it and exits before the
  admin-elevation check — so `-Help` works standalone, without either
  elevation or `-Device`/`-Scenario`. If `-Device`/`-Scenario` are omitted
  and `-Help` isn't passed, it now prints the same usage plus an error
  instead of PowerShell's interactive mandatory-parameter prompt. Not yet
  re-tested on real Windows (no `pwsh` in this dev sandbox) — verify
  `-Help` and the missing-args error path on the laptop along with the next
  `-DryRun` run. Also corrected the top-level `README.md`'s Windows/Linux
  usage examples, which still showed the pre-restructure `-ProfileName
  ssh-link` / hostname-less `apply-profile.sh ssh-link` invocations from
  before the `-Device`/`-Scenario` and `<device> <scenario>` CLI-args change
  — these were stale, not just untested.

**Not yet built:** everything else. This is the first of what's meant to be
a growing set of cross-device scripts in this repo.
