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

## Run it

Click "Open in Cloud Shell" above, or paste this into
[Cloud Shell](https://console.cloud.google.com) (nothing to install —
Cloud Shell already has everything this script needs):

```bash
curl -fsSL "https://raw.githubusercontent.com/security-assignments/kali-launcher/main/launch-kali.sh?$(date +%s)" | bash
```

Or, to read the script before running it:

```bash
git clone https://github.com/security-assignments/kali-launcher
cd kali-launcher
./launch-kali.sh
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
5. Prints how to connect once your instance is running.

## Options

```bash
./launch-kali.sh --help          # show all options
./launch-kali.sh --dry-run       # preview what would be created, without creating anything
./launch-kali.sh --delete-only   # delete the existing instance and exit
./launch-kali.sh --recreate      # delete the existing instance (if any), then create a new one
```

`--delete-only` and `--recreate` ask for confirmation before deleting
anything (it's a real, permanent instance deletion) — add `--force` to
skip the prompt.

If you're using the `curl | bash` one-liner, pass options after `-s --`:

```bash
curl -fsSL "https://raw.githubusercontent.com/security-assignments/kali-launcher/main/launch-kali.sh?$(date +%s)" | bash -s -- --dry-run
```

## What it doesn't do

Everything after "instance is running" — SSH-in-browser, Chrome Remote
Desktop setup — is unchanged; see Part 4 onward of the tutorial.
