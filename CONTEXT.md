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

### `net-profile-control/` (first script, in progress)

Switches a machine's ethernet and/or wifi between DHCP and a static IP by
applying a named "profile" (JSON file), leaving whichever interface isn't
mentioned in the profile untouched. Full design rationale and usage is in
`net-profile-control/README.md` — this file only tracks the *why* behind
decisions and what's actually been verified to work, so a future session
doesn't have to re-derive it. (Originally named `network-profiles/` with
scripts `linux/apply-profile.sh` and `windows/Apply-Profile.ps1`; renamed
2026-07-27 — see the dated entry near the end of this section for why.)

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
- `net-profile-control-linux.sh` refuses to run under WSL (detects via
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
- `linux/apply-profile.sh`'s `find_interfaces()` silently killed the whole
  script partway through, with **zero output**, right after backend
  detection. Root cause: under `set -euo pipefail`, a shell function's exit
  status is that of its *last executed command* if it never explicitly
  `return`s. The role-match test in `find_interfaces()` used a bare `&&`
  chain (`[ ! -d .../wireless ] && [ -d .../device ] && echo "$iface"`) with
  no fallback. When the *last* interface enumerated from `/sys/class/net/*`
  didn't match the requested role (e.g. `wlan0` while filtering for
  `ethernet`), that failing test became the function's return status even
  though it had already correctly echoed the real match (`eth0`) earlier in
  the loop. That non-zero status flows through `candidates="$(find_interfaces
  ...)"` — a bare top-level assignment — and `set -e` kills the script right
  there, with nothing printed since it was just a failed `[` test, not an
  error message. Found 2026-07-27 on real Raspberry Pi hardware via `bash -x`
  (the `-x` trace was needed — normal output gave no clue since it stopped
  clean, not with an error). Order-dependent, so it wasn't guaranteed to
  reproduce on every machine/interface-enumeration order. Fixed by adding an
  explicit `return 0` at the end of `find_interfaces()`. Same bug class also
  found (proactively, not yet hit in testing) in `apply_networkd()`'s
  non-dry-run file-writing block — `[ -n "$gateway" ] && echo "Gateway=..."`
  as a bare mid-block statement — fixed by converting to an explicit `if`.
  This would have bitten the Red Pitaya real-apply path the first time it
  ran with `gateway: null`, which both `ssh-link` profiles use. Lesson: any
  bash function whose result feeds a `set -e` script must not end (or have a
  bare mid-block statement) on a conditional `&&`/test that's allowed to
  fail — either wrap it in `if/fi`, append `|| true` where failure should be
  ignored, or add an explicit `return 0`/`return 1`.

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
  has **not** been fully tested end-to-end yet — no jq/nmcli available in
  the dev sandbox used to write it. First real run was 2026-07-27 on an
  actual Raspberry Pi (`raspberrypi ssh-link --dry-run`): device/scenario
  resolution and nmcli backend auto-detection both confirmed correct, but
  the run died silently right after — see the `find_interfaces()` bug above
  (now fixed). **Not yet re-run** to confirm the dry-run now completes
  end-to-end past that point (BEFORE snapshot, dry-run apply preview,
  "Leaving wifi alone", "Done."). Still needs a real (non-dry-run) apply on
  the Pi, and everything on a Red Pitaya (systemd-networkd branch is
  entirely unexercised on real hardware).
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

- **2026-07-27 (real hardware, after the CLI-arg re-test above): first
  real (non-dry-run) applies on both the Pi and the laptop, plus two new
  findings, both fixed same day.**
  - First `raspberrypi ssh-link --dry-run` run after the `find_interfaces()`
    fix printed `Warning: no NetworkManager connection profile found for
    eth0, skipping.` This turned out to be correct behavior, not a bug: the
    ethernet cable was only plugged in on the laptop end at that point, so
    NetworkManager had never bound `eth0` to a connection (no
    `GENERAL.CONNECTION`), and there was nothing for `nmcli connection
    modify` to target. Re-run with the cable plugged in on **both** ends
    found `Wired connection 1` and produced a correct dry-run plan
    (`address=10.10.10.2/24`) matching `raspberrypi.json`'s `ssh-link`
    scenario exactly. No script change needed — confirms `nmcli_conn_for()`'s
    behavior of only reporting a profile once NM has actually bound one is
    the right call, not a gap to patch.
  - Ran for real (`sudo ./linux/apply-profile.sh raspberrypi ssh-link`) on
    the Pi and the Windows side for real too. `ssh spectrum@10.10.10.2` from
    the laptop then failed with `Connection refused`. Root cause: **Raspberry
    Pi OS ships with `sshd` disabled by default** unless enabled during
    imaging or via `raspi-config` — nothing to do with this script or the
    network config (a "connection refused" is actually a signal the network
    layer *did* work: the host answered, just nothing was listening on 22).
    Fixed by `sudo systemctl enable --now ssh` on the Pi. Documented in
    `network-profiles/README.md`'s Linux usage section so this doesn't need
    re-discovering.
  - After SSH worked, tried switching the Pi back to `home`
    (`ethernet.mode=dhcp`) while the cable was **still plugged directly into
    the laptop** (not moved back to the router). The script appeared to hang
    forever after printing `Configuring ethernet (eth0): mode=dhcp`, with
    Ctrl-C eventually surfacing nmcli's own `Error: Connection activation
    failed: IP configuration could not be reserved (no available address,
    timeout, etc.)`. Root cause: `apply_nmcli()`'s final `nmcli connection up
    "$conn"` had no `--wait`, so it blocked on NetworkManager's own
    (long/unbounded-feeling) default policy waiting for a DHCP lease that
    could never arrive — there was no DHCP server on that direct-to-laptop
    link. Not a network-config bug, but a real script UX gap: no status
    output while waiting, no bounded timeout, and a hard `set -e` exit on
    failure. Fixed in `linux/apply-profile.sh`: added `NMCLI_UP_TIMEOUT=20`,
    changed the final call to `nmcli connection up "$conn" --wait
    "$NMCLI_UP_TIMEOUT"` wrapped in an `if ! ...; then` (prints a status line
    before activating, and on failure a `WARNING` instead of crashing —
    config is still saved and NM keeps retrying in the background). Also
    documented in the README as an expected-behavior note: moving back to
    `dhcp` while still cabled point-to-point to a peer will wait out the 20s
    bound and warn, not hang. **General lesson reinforced**: when a
    scenario's ethernet block sets a static point-to-point address with no
    gateway/DNS (the `ssh-link` shape), switching *back* to `dhcp` on that
    same physical link requires the cable to actually be moved back to a
    real network first — the script can bound/report the failure but can't
    make DHCP succeed with no server present.
  - **Testing status update:** real (non-dry-run) apply now confirmed
    working end-to-end on both the Pi (nmcli backend) and the laptop
    (Windows) for the `ssh-link` scenario, including a live SSH connection
    over the resulting static-IP link. Switching the Pi back to `home` is
    expected to work once the cable is physically moved back to the router
    — not yet re-confirmed after the `--wait`/warning fix (script fix applied
    same day, not yet re-run on hardware). Red Pitaya / systemd-networkd
    branch still entirely unexercised on real hardware.
  - **TODO (pending, blocking further Pi testing):** user needs to physically
    move the Pi's ethernet cable from the laptop back to the router, then
    re-run `sudo ./net-profile-control-linux.sh raspberrypi internet` (path
    and scenario name current as of the renames below — was
    `linux/apply-profile.sh raspberrypi home` when this TODO was written) to
    confirm (a) DHCP now succeeds normally and (b) the new bounded `--wait
    20` + warning-instead-of-hang fix in `apply_nmcli()` behaves as intended.
    Not yet done as of this session — check back on this before assuming the
    `internet` scenario round-trip works on the Pi.

- **2026-07-27 (later same day): renamed `home` → `internet` and
  `kevin-laptop` → `windows-host`.** User felt `home` didn't fit and
  `kevin-laptop` was needlessly tied to one specific machine when the
  intent (per the `<device>`-is-just-a-label design decision above) is a
  device *class*. `profiles/kevin-laptop.json` renamed to
  `profiles/windows-host.json` (`git mv`), its `home` key and
  `raspberrypi.json`'s `home` key both renamed to `internet`. All examples
  in both READMEs and both scripts' usage/help text updated to match.
  Historical entries earlier in this log still say `home`/`kevin-laptop`
  where they're describing what was literally run/observed at the time —
  left as-is rather than rewritten, same convention as other renames in
  this file. Not yet re-tested on hardware under the new names (should be a
  no-op functionally — pure rename, no logic touched — but worth confirming
  `apply-profile.sh windows-host internet` / `-Device windows-host -Scenario
  internet` resolve correctly next time either machine is touched).

- **2026-07-27 (later same day): renamed the whole project
  `network-profiles/` → `net-profile-control/`, and flattened the
  `linux/`/`windows/` subfolders.** User felt `network-profiles` described
  the JSON files more than what the scripts *do*, and that a folder holding
  exactly one file each (`linux/apply-profile.sh`, `windows/Apply-Profile.ps1`)
  wasn't earning its nesting. New layout — everything moved with `git mv`
  (history preserved):
  ```
  net-profile-control/
    profiles/*.json                    # unchanged
    net-profile-control-linux.sh       # was linux/apply-profile.sh
    net-profile-control-windows.ps1    # was windows/Apply-Profile.ps1
  ```
  Both scripts previously resolved `profiles/` as `../profiles` relative to
  their own location (they lived one level down, in `linux/`/`windows/`);
  now that they're siblings of `profiles/`, both were changed to resolve it
  as `profiles` directly (`PROFILES_DIR="${SCRIPT_DIR}/profiles"` in the
  bash script, `Join-Path $PSScriptRoot "profiles"` as the PS1 default for
  `-ProfilesDir`) — **this is the one part of this rename that's more than
  cosmetic**, since a stale `../profiles` after the move would have pointed
  one directory too high and broken profile lookup entirely. All usage/help
  text, both READMEs, and the top-level `README.md` updated to the new
  script names and the flattened path (no more `linux/`/`windows/` prefix in
  invocation examples). Not yet re-tested on either the Pi or the Windows
  laptop under the new paths — the profiles-dir change in particular should
  be verified with a `--dry-run`/`-DryRun` on real hardware before trusting
  a real apply, even though it's a straightforward mechanical change.

**Not yet built:** everything else. This is the first of what's meant to be
a growing set of cross-device scripts in this repo.
