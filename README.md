# kali-launcher

[![Open in Cloud Shell](https://gstatic.com/cloudssh/images/open-btn.svg)](https://console.cloud.google.com/cloudshell/open?cloudshell_git_repo=https://github.com/security-assignments/kali-launcher&cloudshell_tutorial=tutorial.md)

Creates the security-assignments course's Kali GCP instance from Cloud
Shell, retrying across a shortlist of zones/machine-types if you hit a
capacity stockout. Replaces the manual GUI steps in Part 3.2–3.3 of the
[Introduction to GCP tutorial](https://security-assignments.com/tutorials/intro-to-gcp.html)
([source](https://github.com/security-assignments/security-assignments.github.io)).

**Before running this:** you need a GCP project already created, with the
Google account you used to purchase class lab material access (see Part 1
of the tutorial).

## Install and run it

Click "Open in Cloud Shell" above, or paste these commands into
[Cloud Shell](https://console.cloud.google.com):

```bash
curl -fsSLO "https://raw.githubusercontent.com/security-assignments/kali-launcher/main/kali-launcher.sh?$(date +%s)"
bash kali-launcher.sh --install
~/.local/bin/kali-launcher
```

This installs a managed copy at `~/.local/bin/kali-launcher`. Use that full
path in Cloud Shell; its `~/.local/bin` directory is not on `PATH` by default.

Or clone the repository if you want to inspect the script first:

```bash
git clone https://github.com/security-assignments/kali-launcher
cd kali-launcher
bash kali-launcher.sh --install
~/.local/bin/kali-launcher
```

## What it does

1. Checks whether you already have a `kali` instance — if so, it stops
   and tells you how to connect instead of creating a duplicate.
2. Looks up the course's Kali boot image.
3. Enables the Compute Engine API if it isn't already.
4. Fetches current capacity data and tries a shortlist of zones and
   machine types in order (live data first, a built-in fallback list if
   that data can't be fetched), skipping ahead automatically on a
   capacity stockout, until one succeeds.
5. Creates a 200 GB balanced persistent boot disk and prints how to connect
   once your instance is running.

## Options

```bash
~/.local/bin/kali-launcher --help          # show all options
~/.local/bin/kali-launcher --self-update   # update the launcher itself, not the Kali instance
~/.local/bin/kali-launcher --dry-run       # preview without creating anything
~/.local/bin/kali-launcher --delete-only   # delete the existing instance and exit
~/.local/bin/kali-launcher --recreate      # delete and recreate the instance
~/.local/bin/kali-launcher --image NAME    # use an exact shared course image
~/.local/bin/kali-launcher --image-family FAMILY  # use another image family
```

`--delete-only` and `--recreate` ask for confirmation before deleting
anything (it's a real, permanent instance deletion) — add `--force` to
skip the prompt.

You can still run the current published version without installing it:

```bash
curl -fsSL "https://raw.githubusercontent.com/security-assignments/kali-launcher/main/kali-launcher.sh?$(date +%s)" | bash -s -- --dry-run
```

## What it doesn't do

Everything after "instance is running" — SSH-in-browser, Chrome Remote
Desktop setup — is unchanged; see Part 4 onward of the tutorial.
