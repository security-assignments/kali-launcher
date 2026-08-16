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

## Run the launcher

This repo was already cloned into your Cloud Shell home directory. Run:

```bash
./launch-kali.sh
```

It looks up the course's Kali image, enables the Compute Engine API if
needed, and tries a shortlist of zones/machine types in order until one
succeeds — skipping ahead automatically on a capacity stockout.

## Connect

Once it finishes, it prints a zone and a ready-to-run `gcloud compute ssh`
command, or connect via SSH-in-browser from the
[Compute Engine instances page](https://console.cloud.google.com/compute/instances).

<walkthrough-conclusion-trophy></walkthrough-conclusion-trophy>

You're done! Continue with Part 4 of the
[Introduction to GCP tutorial](https://security-assignments.com/tutorials/intro-to-gcp.html)
onward — SSH-in-browser and Chrome Remote Desktop setup are unchanged.
