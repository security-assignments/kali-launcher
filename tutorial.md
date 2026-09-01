# Launch your Kali instance

<walkthrough-project-setup></walkthrough-project-setup>

This walkthrough creates the security-assignments course's Kali GCP
instance, retrying across a shortlist of zones and machine types if you hit
a capacity stockout.

## Select a project

Use the project picker above to select or create the GCP project you set up
with the Google account you used to purchase class lab material access (see
Part 1 of the
[Introduction to GCP tutorial](https://security-assignments.com/tutorials/intro-to-gcp.html)).

**Do not select `security-assignments-kali`** — that's the shared course
project the Kali image itself lives in, and you don't have permission to
create instances there. Pick or create your own project instead.

## Run the launcher

This repo was already cloned into your Cloud Shell home directory. Run
(picking a project above only updates the console, not your terminal
session, so it's passed in explicitly here):

```bash
CLOUDSDK_CORE_PROJECT=<walkthrough-project-id/> bash kali-launcher.sh --install
CLOUDSDK_CORE_PROJECT=<walkthrough-project-id/> ~/.local/bin/kali-launcher
```

Clicking that only pastes the command into the terminal — it doesn't run it.
Click into the terminal and press Enter to actually start it (if the
terminal wasn't already focused, the first Enter may just focus it; press
it again if nothing happens).

It looks up the course's Kali image, enables the Compute Engine API if
needed, and tries a shortlist of zones/machine types in order until one
succeeds — skipping ahead automatically on a capacity stockout.

## Connect

Once it finishes, it prints a zone and a ready-to-run `gcloud compute ssh`
command, or connect via SSH-in-browser from the
[Compute Engine instances page](https://console.cloud.google.com/compute/instances).

## Set this as your default project

The project picker above only affects the console — it's still worth
setting as your terminal's default too, so any other `gcloud` commands you
run later in this session (or a future one) don't need it passed in
explicitly:

```bash
gcloud config set project <walkthrough-project-id/>
```

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

You're done! Continue with Part 4 of the
[Introduction to GCP tutorial](https://security-assignments.com/tutorials/intro-to-gcp.html)
onward — SSH-in-browser and Chrome Remote Desktop setup are unchanged.
