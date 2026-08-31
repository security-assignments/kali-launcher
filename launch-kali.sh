#!/usr/bin/env bash
# launch-kali.sh — creates the course's Kali GCP instance, retrying across
# a shortlist of (zone, machine_type) candidates on stockout.
#
# No `set -e`: attempt_create()'s job is to let `gcloud create` fail and
# classify *why*. errexit would abort on the first (expected, common)
# stockout. Every failure path below is handled by explicit exit-code
# checks instead.
set -uo pipefail

# Colors only when stderr (where nearly all of this script's output goes)
# is a real terminal, and NO_COLOR isn't set — this script is also meant
# to run via `curl | bash`, where raw escape codes would otherwise land in
# a pipe/log instead of a terminal.
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_CYAN=$'\033[36m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD="" C_RESET=""
fi

err() {
  echo "${C_RED}${C_BOLD}ERROR:${C_RESET} $*" >&2
}

IMAGE_PROJECT="security-assignments-kali"
IMAGE_FAMILY="security-assignments-kali"
INSTANCE_NAME="kali"

# Parallel arrays: FALLBACK_ZONES[i] pairs with FALLBACK_MACHINE_TYPES[i].
# Chosen from live kali-stockout-checker BigQuery data on 2026-07-14 — see
# docs/superpowers/specs/2026-07-14-kali-launcher-design.md. Used as a
# safety net (see build_candidate_shortlist(), below) when the live
# candidate feed can't be fetched or parsed — this list will go stale over
# time; it's a snapshot, not a guarantee.
#
# The three c3-standard-4 entries were added 2026-08-17, requiring
# kali-v5-0-3+ (the first image build with the GVNIC guest-os-feature — see
# labs/errata.md in security-assignments.github.io). Zones chosen from
# kali-stockout-checker's `stockout_probes` BigQuery table, filtering to
# real ZONE_RESOURCE_POOL_EXHAUSTED signal (excluding QUOTA_EXCEEDED/
# QUOTA_COOLDOWN_SKIPPED noise, which dominates the raw row count for this
# machine type — the project's C3 quota gets exhausted far more often than
# real stockouts occur) and picking one clean, high-success zone per
# region for resilience against a single region's quota exhaustion.
FALLBACK_ZONES=(us-east1-b us-east4-a us-west1-a us-east4-a us-south1-a us-west1-b us-west3-b us-west4-a us-east1-c)
FALLBACK_MACHINE_TYPES=(n1-standard-4 n1-standard-4 n1-standard-4 n2-standard-4 n2-standard-4 n2-standard-4 c3-standard-4 c3-standard-4 c3-standard-4)

# CANDIDATE_ZONES/CANDIDATE_MACHINE_TYPES are what run_candidates() actually
# reads. Default to the fallback list so anything that sources this script
# without calling main() (or without calling build_candidate_shortlist()
# directly) still sees a sane, non-empty shortlist.
CANDIDATE_ZONES=("${FALLBACK_ZONES[@]}")
CANDIDATE_MACHINE_TYPES=("${FALLBACK_MACHINE_TYPES[@]}")

region_of() {
  local zone="$1"
  echo "${zone%-*}"
}

classify_error() {
  local stderr_text="$1"
  if [[ "$stderr_text" == *"ZONE_RESOURCE_POOL_EXHAUSTED"* ]]; then
    echo "STOCKOUT"
  elif [[ "$stderr_text" =~ Quota\ \'[^\']+\'\ exceeded ]]; then
    echo "QUOTA"
  elif [[ "$stderr_text" == *"does not exist in zone"* ]]; then
    echo "PERMANENT"
  elif [[ "$stderr_text" =~ Required\ \'[^\']+\'\ permission\ for ]]; then
    echo "PERMISSION"
  else
    echo "UNKNOWN"
  fi
}

# How often run_with_dots() prints a "." while waiting, in seconds.
# Overridable so tests can exercise the real polling logic without a real
# wall-clock wait.
DOTS_INTERVAL="${DOTS_INTERVAL:-0.5}"

# Runs "$@" in the background, printing a growing "..." to stderr every
# DOTS_INTERVAL while it's still running — gcloud calls here can take
# 10-20+ seconds with zero output otherwise, which looks hung (found via
# live testing). stdout is discarded; stderr is captured into $REPLY
# (following `read`'s convention, since callers need both the exit code
# and the captured text — a `local out=$(run_with_dots ...)` would put
# this function in a subshell and lose direct access to $!/wait). Returns
# the command's own exit code.
run_with_dots() {
  local stderr_file
  stderr_file=$(mktemp)
  "$@" >/dev/null 2>"$stderr_file" &
  local pid=$!

  local printed_dot="false"
  while kill -0 "$pid" 2>/dev/null; do
    echo -n "." >&2
    printed_dot="true"
    sleep "$DOTS_INTERVAL"
  done
  [[ "$printed_dot" == "true" ]] && echo "" >&2

  wait "$pid"
  local exit_code=$?
  REPLY=$(<"$stderr_file")
  rm -f "$stderr_file"
  return $exit_code
}

resolve_kali_image() {
  local image_name="${1:-}"
  local image_family="${2:-$IMAGE_FAMILY}"
  if [[ -n "$image_name" ]]; then
    gcloud compute images describe "$image_name" \
      --project="$IMAGE_PROJECT" \
      --format="value(name)"
    return
  fi
  gcloud compute images list \
    --project="$IMAGE_PROJECT" \
    --filter="family=$image_family" \
    --format="value(name)" \
    --sort-by=~creationTimestamp \
    --limit=1
}

find_existing_instance() {
  gcloud compute instances list \
    --filter="name=$INSTANCE_NAME" \
    --format="value(name,zone,status)" \
    2>/dev/null
}

# existing: the tab-separated name/zone/status line from
# find_existing_instance() (must be non-empty — caller's job to check).
# force: "true" skips the confirmation prompt.
delete_existing_instance() {
  local existing="$1" force="$2"
  local zone
  IFS=$'\t' read -r _ zone _ <<< "$existing"

  if [[ "$force" != "true" ]]; then
    echo "${C_YELLOW}This will permanently delete instance '$INSTANCE_NAME' in zone $zone.${C_RESET}" >&2
    local reply
    read -r -p "Delete this instance? [y/N] " reply
    case "$reply" in
      y | Y | yes | Yes | YES) ;;
      *)
        echo "Delete cancelled." >&2
        return 1
        ;;
    esac
  fi

  echo "Deleting instance '$INSTANCE_NAME' in zone $zone..." >&2
  run_with_dots gcloud compute instances delete "$INSTANCE_NAME" --zone="$zone" --quiet
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo "${C_GREEN}Deleted.${C_RESET}" >&2
  else
    echo "$REPLY" >&2
  fi
  return $exit_code
}

# Returns 0 once the Compute Engine API is confirmed enabled, 1 if
# enabling it failed — callers must check this before proceeding, since
# every subsequent create attempt would otherwise fail identically for
# every candidate zone (found via live testing: an unchecked `gcloud
# services enable` failure here used to surface 20+ minutes later as a
# confusing raw PERMISSION_DENIED from `compute instances create`).
ensure_compute_api_enabled() {
  local enabled
  enabled=$(gcloud services list --enabled \
    --filter="config.name=compute.googleapis.com" \
    --format="value(config.name)")
  if [[ -n "$enabled" ]]; then
    return 0
  fi

  echo "Compute Engine API is not enabled yet. Enabling it now (this can take a minute)..." >&2
  run_with_dots gcloud services enable compute.googleapis.com --quiet
  local exit_code=$?
  local stderr_output="$REPLY"
  if [[ $exit_code -eq 0 ]]; then
    return 0
  fi

  echo "" >&2
  err "Could not enable the Compute Engine API."
  if [[ "$stderr_output" == *"BILLING_NOT_FOUND"* || "$stderr_output" == *"Billing account"* ]]; then
    echo "${C_YELLOW}This project has no billing account linked. In the GCP Console, go to" >&2
    echo "Billing and link a billing account to this project, then run this again.${C_RESET}" >&2
    echo "" >&2
  fi
  # Always show gcloud's own error too, even after a friendly summary
  # above — it often carries specifics a generic summary can't.
  echo "$stderr_output" >&2

  # This error's own text never contains a full clickable activation
  # link. gcloud does generate one, but only from an actual Compute API
  # call, as part of its SERVICE_DISABLED response -- so make one, using
  # a read-only call that can't create anything even if the API somehow
  # became enabled in the few seconds since the check above (e.g.
  # enable-propagation catching up): the "is this API enabled" gate is
  # per-project-per-service, not per-method, so any Compute API call
  # reproduces the identical error and link.
  local probe_stderr
  probe_stderr=$(gcloud compute regions list --limit=1 --quiet 2>&1 1>/dev/null)
  if [[ -n "$probe_stderr" ]]; then
    echo "" >&2
    echo "$probe_stderr" >&2
  fi

  return 1
}

CANDIDATE_FEED_URL="https://storage.googleapis.com/security-assignments-kali-stockout-checker/latest-candidates.json"

# Fetches and parses kali-stockout-checker's public candidate feed.
# On success: prints zero or more "zone<TAB>machine_type" lines to stdout
# (filtered to supported -standard-4 machine types with is_available == 1,
# sorted n2 before n1 before c3, then by last_checked DESC) and returns 0.
# On any failure (network, empty body, malformed/unexpected JSON): prints
# nothing and returns 1. Never fatal to the caller — see
# build_candidate_shortlist().
fetch_live_candidates() {
  local raw
  raw=$(curl -fsSL --max-time 5 "$CANDIDATE_FEED_URL" 2>/dev/null)
  local curl_exit=$?
  if [[ $curl_exit -ne 0 || -z "$raw" ]]; then
    return 1
  fi

  local parsed
  parsed=$(python3 -c '
import json
import sys

try:
    data = json.load(sys.stdin)
    candidates = data["candidates"]
    filtered = [
        c for c in candidates
        if str(c.get("machine_type", "")).endswith("-standard-4")
        and c.get("is_available") == 1
        and c.get("family") in ("n1", "n2", "c3")
    ]
    # Stable two-pass sort: newest first within each family tier, with N2
    # preferred over N1 and C3 last because student C3 quota is less predictable.
    filtered.sort(key=lambda c: c["last_checked"], reverse=True)
    filtered.sort(key=lambda c: {"n2": 0, "n1": 1, "c3": 2}[c["family"]])
    for c in filtered:
        print(c["zone"] + "\t" + c["machine_type"])
except Exception:
    sys.exit(1)
' <<< "$raw")
  local parse_exit=$?
  if [[ $parse_exit -ne 0 ]]; then
    return 1
  fi

  printf '%s\n' "$parsed"
  return 0
}

# Populates CANDIDATE_ZONES/CANDIDATE_MACHINE_TYPES: live candidates from
# fetch_live_candidates() (if it succeeds) followed by every
# FALLBACK_ZONES/FALLBACK_MACHINE_TYPES entry whose exact
# (zone, machine_type) pair isn't already present among the live
# candidates. Merging into one array (rather than trying live and
# fallback as two separate run_candidates() calls) means
# run_candidates()'s existing skip_regions logic covers both tiers in a
# single pass, for free.
build_candidate_shortlist() {
  local live_output
  LIVE_ZONES=()
  LIVE_MACHINE_TYPES=()

  if live_output=$(fetch_live_candidates); then
    local zone machine_type
    while IFS=$'\t' read -r zone machine_type; do
      [[ -n "$zone" ]] || continue
      LIVE_ZONES+=("$zone")
      LIVE_MACHINE_TYPES+=("$machine_type")
    done <<< "$live_output"
  else
    echo "Could not fetch live capacity data from kali-stockout-checker — using the built-in shortlist." >&2
  fi

  if [[ ${#LIVE_ZONES[@]} -gt 0 ]]; then
    echo "Using ${#LIVE_ZONES[@]} live capacity candidates from kali-stockout-checker." >&2
  else
    echo "Live capacity data had no usable candidates — using the built-in shortlist." >&2
  fi

  CANDIDATE_ZONES=("${LIVE_ZONES[@]}")
  CANDIDATE_MACHINE_TYPES=("${LIVE_MACHINE_TYPES[@]}")

  local i j is_dup
  for ((i = 0; i < ${#FALLBACK_ZONES[@]}; i++)); do
    is_dup="false"
    for ((j = 0; j < ${#LIVE_ZONES[@]}; j++)); do
      if [[ "${FALLBACK_ZONES[$i]}" == "${LIVE_ZONES[$j]}" && "${FALLBACK_MACHINE_TYPES[$i]}" == "${LIVE_MACHINE_TYPES[$j]}" ]]; then
        is_dup="true"
        break
      fi
    done
    if [[ "$is_dup" == "false" ]]; then
      CANDIDATE_ZONES+=("${FALLBACK_ZONES[$i]}")
      CANDIDATE_MACHINE_TYPES+=("${FALLBACK_MACHINE_TYPES[$i]}")
    fi
  done
}

attempt_create() {
  local zone="$1" machine_type="$2" image="$3" dry_run="$4"
  local cmd=(gcloud compute instances create "$INSTANCE_NAME"
    --zone="$zone"
    --machine-type="$machine_type"
    --image="$image"
    --image-project="$IMAGE_PROJECT"
    --boot-disk-type=pd-balanced
    --enable-nested-virtualization
    --quiet)

  # c3 (and any future third-generation-and-later family, e.g. c4/n4) is
  # gVNIC-only — virtio-net isn't offered at all, confirmed via GCP's
  # machine-comparison table. Requires kali-v5-0-3+ (first image built with
  # the GVNIC guest-os-feature). Confirmed live this doesn't change N1/N2
  # behavior: leaving nic-type unset on those still defaults to virtio-net
  # even on a GVNIC-tagged image, so this is scoped to c3 only rather than
  # applied unconditionally.
  if [[ "$machine_type" == c3-* ]]; then
    cmd+=(--network-interface=nic-type=GVNIC)
  fi

  # No --min-cpu-platform here: GCP rejects "Intel Haswell" for N2
  # machine types (confirmed live during final review — n2-standard-4
  # requires cascadelake), and that error text matches none of
  # classify_error()'s patterns, so it would misclassify as UNKNOWN and
  # halt the whole retry loop. --enable-nested-virtualization alone is
  # sufficient on both N1 and N2 (confirmed live: N1 lands on Broadwell,
  # N2 lands on Cascade Lake, both qualify for nested virt on their own).
  #
  # --quiet matters more than usual here: this function captures stderr
  # into a variable below (invisible to the user) while leaving stdin
  # attached to the real terminal. Without --quiet, an interactive
  # confirmation gcloud sometimes issues here — e.g. "API ... not
  # enabled ... Would you like to enable and retry?", which can fire even
  # after ensure_compute_api_enabled() succeeds, due to enable-propagation
  # lag — would print into that captured (invisible) stream while still
  # blocking on a real stdin read, silently eating the user's next
  # keystroke as its answer (found via live testing — a stray Enter
  # answered "N" with no visible prompt at all). --quiet forces gcloud to
  # fail loud instead, which classify_error() then handles normally.

  if [[ "$dry_run" == "true" ]]; then
    echo "DRYRUN: ${cmd[*]}" >&2
    echo "DRYRUN"
    return 0
  fi

  run_with_dots "${cmd[@]}"
  local exit_code=$?
  local stderr_output="$REPLY"

  if [[ $exit_code -eq 0 ]]; then
    echo "SUCCESS"
    return 0
  fi

  local classification
  classification=$(classify_error "$stderr_output")
  if [[ "$classification" == "UNKNOWN" ]]; then
    echo "$stderr_output" >&2
  fi
  echo "$classification"
}

run_candidates() {
  local image="$1" dry_run="$2"
  # Space-padded string used as a simple set of region/family keys to skip.
  # A plain scalar here is a real bug (found in task-8 review): the real shortlist
  # has non-adjacent duplicate regions (us-east4 at index 1 and 3, us-west1
  # at index 2 and 5), so a run that hits QUOTA in two different regions
  # would forget the first region's skip once the second overwrote a
  # scalar, redundantly re-attempting a candidate already known to fail.
  local skip_quota_pools=" "
  local attempts=()
  local i

  for ((i = 0; i < ${#CANDIDATE_ZONES[@]}; i++)); do
    local zone="${CANDIDATE_ZONES[$i]}"
    local machine_type="${CANDIDATE_MACHINE_TYPES[$i]}"
    local region
    region=$(region_of "$zone")
    local family="${machine_type%%-*}"
    local quota_key="$region/$family"

    if [[ "$skip_quota_pools" == *" $quota_key "* ]]; then
      attempts+=("$zone|$machine_type|QUOTA_SKIPPED")
      echo "${C_YELLOW}Skipping $zone ($machine_type) — $family already hit a quota limit in $region${C_RESET}" >&2
      continue
    fi

    echo "${C_CYAN}${C_BOLD}Trying $zone ($machine_type)...${C_RESET}" >&2
    local result
    result=$(attempt_create "$zone" "$machine_type" "$image" "$dry_run")
    attempts+=("$zone|$machine_type|$result")

    case "$result" in
      SUCCESS)
        echo "$zone|$machine_type"
        return 0
        ;;
      QUOTA)
        echo "${C_YELLOW}  $family quota exceeded in $region — skipping remaining $family candidates there${C_RESET}" >&2
        skip_quota_pools="$skip_quota_pools$quota_key "
        ;;
      STOCKOUT)
        echo "${C_YELLOW}  stockout, trying next candidate${C_RESET}" >&2
        ;;
      PERMANENT)
        echo "${C_YELLOW}  not offered in this zone, trying next candidate${C_RESET}" >&2
        ;;
      DRYRUN)
        :
        ;;
      PERMISSION)
        echo "" >&2
        err "You don't have permission to create Compute Engine instances in this project."
        echo "Make sure you're on your own GCP project (not '$IMAGE_PROJECT' — that's the" >&2
        echo "shared course project the Kali image lives in, not one you have create rights" >&2
        echo "on) and that you have the Editor or Owner role there." >&2
        return 2
        ;;
      UNKNOWN)
        err "Unexpected error creating instance in $zone — stopping."
        return 2
        ;;
    esac
  done

  if [[ "$dry_run" == "true" ]]; then
    return 0
  fi

  echo "" >&2
  echo "${C_YELLOW}${C_BOLD}Every candidate failed:${C_RESET}" >&2
  local attempt
  for attempt in "${attempts[@]}"; do
    echo "  $attempt" >&2
  done
  echo "" >&2
  echo "This can happen when GCP capacity is tight across every candidate zone/machine type." >&2
  echo "Try running this script again in a few minutes, or create the instance manually via the GCP Console as a last resort." >&2
  return 1
}

print_help() {
  # echo (a bash builtin), not `cat <<EOF` (an external command) — --help
  # must work even with a broken PATH, since it should be usable before
  # a student has confirmed anything about their environment is working.
  echo "Usage: launch-kali.sh [OPTIONS]"
  echo ""
  echo "Creates the security-assignments course's Kali GCP instance in the"
  echo "active gcloud project, retrying across a shortlist of zones and machine"
  echo "types if you hit a capacity stockout."
  echo ""
  echo "Options:"
  echo "  --dry-run       Show what would be done without creating anything."
  echo "  --delete-only   Delete the existing 'kali' instance and exit. Does not"
  echo "                  create a new one."
  echo "  --recreate      Delete the existing 'kali' instance (if any), then"
  echo "                  create a new one."
  echo "  --force         Skip the confirmation prompt when deleting. Used with"
  echo "                  --delete-only or --recreate."
  echo "  --image NAME    Use an exact image from project '$IMAGE_PROJECT'."
  echo "  --image-family FAMILY"
  echo "                  Use the newest image in a different image family."
  echo "  --help, -h      Show this help message and exit."
  echo ""
  echo "Examples:"
  echo "  ./launch-kali.sh                     Create the instance (or report it already exists)"
  echo "  ./launch-kali.sh --dry-run           Preview what would be created, without creating anything"
  echo "  ./launch-kali.sh --delete-only       Delete the existing instance"
  echo "  ./launch-kali.sh --recreate          Delete and recreate the instance"
  echo "  ./launch-kali.sh --recreate --force  Delete and recreate without a confirmation prompt"
  echo "  ./launch-kali.sh --image-family kali-fai-base-testing"
}

main() {
  local dry_run="false"
  local delete_only="false"
  local recreate="false"
  local force="false"
  local image_override=""
  local image_family_override="$IMAGE_FAMILY"
  local image_family_was_set="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --help | -h)
        print_help
        exit 0
        ;;
      --dry-run)
        dry_run="true"
        ;;
      --delete-only)
        delete_only="true"
        ;;
      --recreate)
        recreate="true"
        ;;
      --force)
        force="true"
        ;;
      --image=*)
        image_override="${1#*=}"
        [[ -n "$image_override" ]] || { err "--image requires a non-empty image name."; exit 1; }
        ;;
      --image)
        [[ $# -ge 2 && -n "$2" ]] || { err "--image requires an image name."; exit 1; }
        image_override="$2"
        shift
        ;;
      --image-family=*)
        image_family_override="${1#*=}"
        [[ -n "$image_family_override" ]] || { err "--image-family requires a non-empty family name."; exit 1; }
        image_family_was_set="true"
        ;;
      --image-family)
        [[ $# -ge 2 && -n "$2" ]] || { err "--image-family requires a family name."; exit 1; }
        image_family_override="$2"
        image_family_was_set="true"
        shift
        ;;
      *)
        err "unknown argument: $1"
        echo "Run with --help to see available options." >&2
        exit 1
        ;;
    esac
    shift
  done

  if [[ -n "$image_override" && "$image_family_was_set" == "true" ]]; then
    err "--image and --image-family cannot be used together."
    exit 1
  fi

  if [[ "$dry_run" == "true" && ( "$delete_only" == "true" || "$recreate" == "true" ) ]]; then
    err "--dry-run cannot be combined with --delete-only or --recreate."
    exit 1
  fi

  if [[ "$delete_only" == "true" && "$recreate" == "true" ]]; then
    err "--delete-only and --recreate cannot be used together."
    exit 1
  fi

  if ! command -v gcloud >/dev/null 2>&1; then
    err "gcloud CLI not found. Run this in Cloud Shell, or install the Google Cloud CLI first."
    exit 1
  fi

  local project
  project=$(gcloud config get-value project 2>/dev/null)
  if [[ -z "$project" ]]; then
    err "No active gcloud project. Run 'gcloud config set project <your-project-id>' first."
    exit 1
  fi

  if [[ "$project" == "$IMAGE_PROJECT" ]]; then
    err "Active project is '$IMAGE_PROJECT' — that's the shared course"
    echo "project the Kali image lives in, not a project you own. You won't have" >&2
    echo "permission to create instances there." >&2
    echo "Select or create your own GCP project instead (see Part 1 of the" >&2
    echo "intro-to-gcp tutorial), then run this again." >&2
    exit 1
  fi

  local existing
  existing=$(find_existing_instance)

  if [[ "$delete_only" == "true" ]]; then
    if [[ -z "$existing" ]]; then
      echo "No instance named '$INSTANCE_NAME' exists. Nothing to delete." >&2
      exit 0
    fi
    if delete_existing_instance "$existing" "$force"; then
      exit 0
    else
      exit 1
    fi
  fi

  if [[ "$recreate" == "true" && -n "$existing" ]]; then
    # Declining the delete is not a failure here (unlike --delete-only,
    # where deletion was the whole point) — just leave $existing set so
    # the "already exists" branch below reports it normally.
    if delete_existing_instance "$existing" "$force"; then
      existing=""
    fi
  fi

  if [[ -n "$existing" ]]; then
    echo "An instance named '$INSTANCE_NAME' already exists:" >&2
    echo "  $existing" >&2
    echo "Connect to it from the GCP Console, or delete it first if you want to start over." >&2
    exit 0
  fi

  echo "Looking up the Kali image..." >&2
  local image
  image=$(resolve_kali_image "$image_override" "$image_family_override")
  if [[ -z "$image" ]]; then
    if [[ -n "$image_override" ]]; then
      err "Could not find the Kali image (project=$IMAGE_PROJECT, image=$image_override)."
    else
      err "Could not find the Kali image (project=$IMAGE_PROJECT, family=$image_family_override)."
    fi
    echo "This usually means you're signed in to the wrong Google account — use the @gmail.com account you used to purchase class lab access (see Part 1 of the intro-to-gcp tutorial)." >&2
    exit 1
  fi
  echo "${C_GREEN}Found image: $image${C_RESET}" >&2

  if ! ensure_compute_api_enabled; then
    exit 1
  fi

  build_candidate_shortlist

  local winner
  if winner=$(run_candidates "$image" "$dry_run"); then
    if [[ "$dry_run" == "true" ]]; then
      echo "" >&2
      echo "Dry run complete. No instance was created." >&2
      exit 0
    fi
    local zone="${winner%%|*}"
    echo "" >&2
    echo "${C_GREEN}${C_BOLD}Kali instance '$INSTANCE_NAME' created in $zone.${C_RESET}" >&2
    # A direct SSH-in-browser deep link is possible but deliberately not
    # done: the real URL (confirmed live) is
    # https://ssh.cloud.google.com/v2/ssh/projects/PROJECT_ID/zones/ZONE/instances/INSTANCE?authuser=0&hl=en_US&projectNumber=PROJECT_NUMBER&useAdminProxy=true
    # -- undocumented by Google, so no guarantee it's stable. The
    # structural path (.../instances/INSTANCE, no query string) alone
    # was confirmed to work live, but authuser=0 hardcodes "your first
    # signed-in Google account", wrong for anyone whose course account
    # isn't that one, and projectNumber would need an extra `gcloud
    # projects describe` call just for a param whose necessity is
    # unconfirmed. Not worth the fragility for a convenience link when
    # the instances-list link below already gets students to the same
    # SSH button in one more click.
    echo "${C_CYAN}Connect via SSH-in-browser:${C_RESET}" >&2
    echo "  ${C_CYAN}https://console.cloud.google.com/compute/instances?project=$project${C_RESET}" >&2
    echo "  or run:" >&2
    echo "  gcloud --project=$project compute ssh $INSTANCE_NAME --zone=$zone" >&2
    exit 0
  else
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]:-$0}" == "${0}" ]]; then
  main "$@"
fi
