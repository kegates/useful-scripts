# useful-scripts

A repo of scripts usable across all of the user's devices — Windows 10/11
laptops/desktops, Raspberry Pi 5s (Raspberry Pi OS), and Red Pitaya boards
(Red Pitaya OS). Pull the repo on a new/reimaged machine and the scripts
just work from the command line, without per-OS relearning.

Each sub-project lives in its own folder with its own README covering full
usage. This file is just an index.

## Sub-projects

### [`network-profiles/`](network-profiles/README.md)

Switch a machine's ethernet and/or wifi between DHCP and a static IP by
applying a named "profile" (JSON file). Same profile files, same command
shape across Windows, Raspberry Pi OS, and Red Pitaya OS.

```powershell
# Windows (native PowerShell, as Administrator)
.\network-profiles\windows\Apply-Profile.ps1 -ProfileName ssh-link
```

```bash
# Linux (Raspberry Pi OS, Red Pitaya OS)
sudo ./network-profiles/linux/apply-profile.sh ssh-link
```

See [`network-profiles/README.md`](network-profiles/README.md) for the full
profile format, prerequisites, and what the scripts print.

## Windows: getting scripts to run at all

If a script in this repo won't run on Windows with an error like
"...is not digitally signed. You cannot run this script on the current
system", that's Windows blocking files that arrived via copy/zip/OneDrive
rather than `git clone` (the "Mark of the Web"). Two fixes, roughly in the
order to try them:

```powershell
# 1. Unblock the files themselves (no admin needed) — sufficient on its own
#    on some machines
Get-ChildItem -Path <path-to-this-repo> -Recurse | Unblock-File

# 2. Check the current policy before changing anything
Get-ExecutionPolicy -List

# 3. If still blocked (e.g. a stricter CurrentUser execution policy),
#    allow locally run scripts for your user account (no admin needed)
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

A `git clone` on a given machine shouldn't need either of these — cloned
files aren't marked as downloaded the way a copied/extracted file is. See
each sub-project's README for any project-specific notes on this.
