# network-profiles

Switch a machine's ethernet and/or wifi between DHCP and a static IP by applying
a named "profile", without touching whichever interface isn't mentioned in the
profile. Works the same way (same profile files, same command shape) across
Windows 10/11, Raspberry Pi OS, and Red Pitaya OS.

## Layout

```
network-profiles/
  profiles/                     # JSON profile files, shared across all OSes
    kevin-laptop.json
    raspberrypi.json
    redpitaya.json
  linux/apply-profile.sh        # Raspberry Pi OS, Red Pitaya OS, any Debian-based Linux
  windows/Apply-Profile.ps1     # native Windows PowerShell
```

## Profile files

Each JSON file is a **device profile** — a label you choose and pass
explicitly on the command line, not something the script auto-detects:

```
profiles/<device>.json
```

`<device>` doesn't have to match the machine's actual hostname. It's just a
name you make up for a set of settings — e.g. `kevin-laptop` for one specific
machine, or something like `raspberrypi`/`redpitaya` shared by every device
of that class. If several machines want identical settings (every Raspberry
Pi, say), they can all pass the same `<device>` name rather than needing one
file each. You supply `<device>` explicitly every time you run the script —
there's no hostname lookup to trip over.

Within that file, each key is a **scenario** name — the thing you also pass on
the command line (`apply-profile <device> ssh-link`, `apply-profile <device>
home`, etc.):

```json
{
  "home": {
    "description": "Normal internet usage: everything on DHCP.",
    "ethernet": { "mode": "dhcp" },
    "wifi": { "mode": "dhcp" }
  },
  "ssh-link": {
    "description": "optional, just for humans",
    "ethernet": {
      "mode": "static",
      "address": "10.10.10.1",
      "prefix": 24,
      "gateway": null,
      "dns": []
    }
  }
}
```

- Omit `ethernet` or `wifi` entirely within a scenario to leave that
  interface untouched — this is how "static IP on ethernet, wifi stays on
  internet" works.
- `mode` is `"dhcp"` or `"static"`. For `"dhcp"`, no other fields are needed.
- `gateway` and `dns` are optional (fine to leave `null`/`[]` for a direct
  point-to-point link that doesn't need a gateway).

To add a new device profile, copy an existing file to `<new-device>.json` and
adjust the scenarios/addresses. To add a new scenario to an existing device
profile, just add another top-level key to that file.

## Windows prerequisite: script execution policy

If you got these files any way other than `git clone` (copied over a share,
extracted from a zip, synced via OneDrive, etc.), Windows tags them with a
"Mark of the Web" and PowerShell will refuse to run them at all:
`...is not digitally signed. You cannot run this script on the current
system.` **Check this first**:

```powershell
Get-ChildItem -Path <path-to-network-profiles> -Recurse | Unblock-File
```

On one test machine (synced via OneDrive) this alone was enough — no
execution-policy change needed. On another (a fresh PC being tested), the
`CurrentUser` execution policy itself was the blocker and `Unblock-File`
alone wasn't enough. Check the current policy first:

```powershell
Get-ExecutionPolicy -List
```

If `CurrentUser` shows `Restricted` (or `Undefined` and `LocalMachine` is
`Restricted`), allow locally run scripts for your user account (no admin
needed):

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Both are common fixes depending on the machine — try `Unblock-File` first
since it's non-invasive, but don't be surprised if a given machine also needs
the `Set-ExecutionPolicy` change. A `git clone` on a given machine shouldn't
need either of these — cloned files aren't marked as downloaded the way a
copied/extracted file is.

## Usage

**Linux** (Raspberry Pi OS, Red Pitaya OS):

```bash
sudo ./linux/apply-profile.sh raspberrypi ssh-link
sudo ./linux/apply-profile.sh raspberrypi home
./linux/apply-profile.sh raspberrypi ssh-link --dry-run     # preview, no sudo needed
```

Requires `jq` (`sudo apt install jq`). The script auto-detects whether the
machine runs NetworkManager (`nmcli`) or `systemd-networkd` and uses the
right one:

- **Raspberry Pi OS Bookworm and later** uses NetworkManager by default →
  the script edits the connection profile via `nmcli`.
- **Red Pitaya OS** uses `systemd-networkd` directly → the script writes
  `/etc/systemd/network/00-profile-<ethernet|wifi>.network` (the `00-`
  prefix makes it win over Red Pitaya's own default `wired.network`/
  `wireless.network`, since systemd-networkd applies only the first
  matching file per interface in lexical order) and reloads with
  `networkctl`.

**Raspberry Pi OS: SSH is disabled by default.** Applying a `static`
ethernet profile so you can SSH into the Pi only works if `sshd` is actually
running. Unless SSH was enabled during imaging (Raspberry Pi Imager's
"Enable SSH" option) or via `raspi-config`, a fresh install has it off, which
shows up as `ssh: connect to host ... port 22: Connection refused` — the
network config is fine at that point (a "connection refused" means the host
answered, just with nothing listening on 22), the service just isn't running.
Check and fix with:

```bash
sudo systemctl status ssh
sudo systemctl enable --now ssh   # if it's not active
```

**Switching ethernet back to `dhcp` waits for an actual DHCP server.** The
script activates the connection with a 20s bound (`nmcli connection up
--wait 20`) rather than hanging indefinitely, but if there's genuinely no
DHCP server reachable on that link — e.g. the cable is still plugged
directly into another device from a prior `ssh-link`-style scenario instead
of a router/switch — it will still sit for the full 20s before printing a
`WARNING` and moving on. Move the cable back to the normal network first if
you hit this.

**Windows** (native PowerShell, run as Administrator):

```powershell
.\windows\Apply-Profile.ps1 -Device kevin-laptop -Scenario ssh-link
.\windows\Apply-Profile.ps1 -Device kevin-laptop -Scenario home
.\windows\Apply-Profile.ps1 -Device kevin-laptop -Scenario ssh-link -DryRun
```

The ethernet/wifi adapter is picked automatically by physical media type, so
it doesn't matter what the adapter is named on a given machine.

**Help**: both scripts print full usage (device/scenario semantics, options,
examples) and exit without requiring any other arguments:

```bash
./linux/apply-profile.sh --help    # or -h
```

```powershell
.\windows\Apply-Profile.ps1 -Help
```

## What the scripts print

Both scripts now report state, not just act on it, for every interface the
profile touches:

- **Pre-checks on the profile itself**, before touching anything: a
  static gateway that isn't in the same subnet as the address, DNS entries
  that don't look like valid IPv4 addresses, or more than one candidate
  ethernet/wifi adapter found on the machine (ambiguous auto-detection —
  it uses the first match and tells you which one).
- **BEFORE snapshot**: link state, current address(es), current default
  gateway, current DNS, and the backend's own view of the configured method
  (`nmcli`'s `ipv4.method`, or the matching `.network` file on
  `systemd-networkd`). Flags an APIPA (`169.254.x.x`) address as suspicious
  (usually means DHCP isn't getting a lease) and notes if the link isn't up.
- On a real run (not `--dry-run`): applies the change, waits a second, then
  prints an **AFTER snapshot** in the same shape, plus an explicit
  `OK`/`WARNING` verification that the resulting address/gateway actually
  match what the profile asked for (mode=static), or that the address isn't
  still APIPA (mode=dhcp).
- `--dry-run` only prints the BEFORE snapshot and the pre-checks — nothing
  is applied, so there's no AFTER.

## Important: don't run the Linux script from WSL

WSL has its own virtual network stack — it cannot configure the physical
NICs of the Windows host it's running on. If you're on a Windows machine,
always run `windows\Apply-Profile.ps1` from a native Windows PowerShell
(as Administrator), even if you normally live in WSL for everything else.
`linux/apply-profile.sh` will refuse to run under WSL with a pointer to this.

## Applying a profile over the connection you're using

If you SSH into a machine over the same interface you're about to
reconfigure (e.g. re-running `ssh-link` on the Pi over the ethernet cable
itself), the connection will drop the moment the address changes. That's
expected — reconnect using the new address afterwards.

## "No ethernet/wifi adapter found" warning

If a machine genuinely doesn't have that kind of adapter (e.g. a laptop with
no built-in ethernet port and no dongle plugged in), the script prints a
warning and skips that role rather than failing — this is expected, not a
bug. `Get-NetAdapter -Physical` / the Linux interface scan only see hardware
that's actually present. Test the ethernet side on a machine that has a NIC.

## Known limitation: wifi as the direct link

The "static ethernet, DHCP wifi" direction works like a crossover cable:
both ends just need matching static IPs, no router involved. The reverse
(wired connection to the internet, direct wifi link between two devices for
SSH) is **not** fully solved by this script yet — two wifi *clients* can't
just static-IP their way into talking to each other; one side needs to host
an access point (or the link needs ad-hoc/IBSS mode, which isn't reliably
supported across Windows/Linux/Red Pitaya). This script will correctly set
a static IP on the wifi interface, but establishing the actual radio link
(hosting/joining an AP) is a separate piece — ask if you want that built out
as a follow-on (e.g. a `wifi-hotspot` profile type).
