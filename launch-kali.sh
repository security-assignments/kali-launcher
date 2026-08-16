#!/usr/bin/env bash
# launch-kali.sh — creates the course's Kali GCP instance, retrying across
# a shortlist of (zone, machine_type) candidates on stockout.
#
# No `set -e`: attempt_create()'s job is to let `gcloud create` fail and
# classify *why*. errexit would abort on the first (expected, common)
# stockout. Every failure path below is handled by explicit exit-code
# checks instead.
set -uo pipefail

IMAGE_PROJECT="security-assignments-kali"
IMAGE_FAMILY="security-assignments-kali"
INSTANCE_NAME="kali"

# Parallel arrays: FALLBACK_ZONES[i] pairs with FALLBACK_MACHINE_TYPES[i].
# Chosen from live kali-stockout-checker BigQuery data on 2026-07-14 — see
# docs/superpowers/specs/2026-07-14-kali-launcher-design.md. Used as a
# safety net (see build_candidate_shortlist(), below) when the live
# candidate feed can't be fetched or parsed — this list will go stale over
# time; it's a snapshot, not a guarantee.
FALLBACK_ZONES=(us-east1-b us-east4-a us-west1-a us-east4-a us-south1-a us-west1-b)
FALLBACK_MACHINE_TYPES=(n1-standard-4 n1-standard-4 n1-standard-4 n2-standard-4 n2-standard-4 n2-standard-4)

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
  else
    echo "UNKNOWN"
  fi
}

resolve_kali_image() {
  gcloud compute images list \
    --project="$IMAGE_PROJECT" \
    --filter="family=$IMAGE_FAMILY" \
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
    echo "This will permanently delete instance '$INSTANCE_NAME' in zone $zone." >&2
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
  gcloud compute instances delete "$INSTANCE_NAME" --zone="$zone" --quiet >&2
  local exit_code=$?
  if [[ $exit_code -eq 0 ]]; then
    echo "Deleted." >&2
  fi
  return $exit_code
}

ensure_compute_api_enabled() {
  local enabled
  enabled=$(gcloud services list --enabled \
    --filter="config.name=compute.googleapis.com" \
    --format="value(config.name)")
  if [[ -z "$enabled" ]]; then
    echo "Compute Engine API is not enabled yet. Enabling it now (this can take a minute)..." >&2
    gcloud services enable compute.googleapis.com
  fi
}

CANDIDATE_FEED_URL="https://storage.googleapis.com/security-assignments-kali-stockout-checker/latest-candidates.json"

# Fetches and parses kali-stockout-checker's public candidate feed.
# On success: prints zero or more "zone<TAB>machine_type" lines to stdout
# (filtered to -standard-4 machine types with is_available == 1, sorted
# by family DESC then last_checked DESC) and returns 0.
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
    ]
    filtered.sort(key=lambda c: (c["family"], c["last_checked"]), reverse=True)
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
    --enable-nested-virtualization)
  # No --min-cpu-platform here: GCP rejects "Intel Haswell" for N2
  # machine types (confirmed live during final review — n2-standard-4
  # requires cascadelake), and that error text matches none of
  # classify_error()'s patterns, so it would misclassify as UNKNOWN and
  # halt the whole retry loop. --enable-nested-virtualization alone is
  # sufficient on both N1 and N2 (confirmed live: N1 lands on Broadwell,
  # N2 lands on Cascade Lake, both qualify for nested virt on their own).

  if [[ "$dry_run" == "true" ]]; then
    echo "DRYRUN: ${cmd[*]}" >&2
    echo "DRYRUN"
    return 0
  fi

  # Two-step exit-code capture: `local stderr_output=$(...)` on one line
  # would overwrite $? with `local`'s own status before we could read it.
  local stderr_output
  stderr_output=$("${cmd[@]}" 2>&1 1>/dev/null)
  local exit_code=$?

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
  # Space-padded string used as a simple set of regions to skip — a plain
  # scalar here is a real bug (found in task-8 review): the real shortlist
  # has non-adjacent duplicate regions (us-east4 at index 1 and 3, us-west1
  # at index 2 and 5), so a run that hits QUOTA in two different regions
  # would forget the first region's skip once the second overwrote a
  # scalar, redundantly re-attempting a candidate already known to fail.
  local skip_regions=" "
  local attempts=()
  local i

  for ((i = 0; i < ${#CANDIDATE_ZONES[@]}; i++)); do
    local zone="${CANDIDATE_ZONES[$i]}"
    local machine_type="${CANDIDATE_MACHINE_TYPES[$i]}"
    local region
    region=$(region_of "$zone")

    if [[ "$skip_regions" == *" $region "* ]]; then
      attempts+=("$zone|$machine_type|QUOTA_SKIPPED")
      echo "Skipping $zone ($machine_type) — $region already hit a quota limit" >&2
      continue
    fi

    echo "Trying $zone ($machine_type)..." >&2
    local result
    result=$(attempt_create "$zone" "$machine_type" "$image" "$dry_run")
    attempts+=("$zone|$machine_type|$result")

    case "$result" in
      SUCCESS)
        echo "$zone|$machine_type"
        return 0
        ;;
      QUOTA)
        echo "  quota exceeded in $region — skipping remaining $region candidates" >&2
        skip_regions="$skip_regions$region "
        ;;
      STOCKOUT)
        echo "  stockout, trying next candidate" >&2
        ;;
      PERMANENT)
        echo "  not offered in this zone, trying next candidate" >&2
        ;;
      DRYRUN)
        :
        ;;
      UNKNOWN)
        echo "Unexpected error creating instance in $zone — stopping." >&2
        return 2
        ;;
    esac
  done

  if [[ "$dry_run" == "true" ]]; then
    return 0
  fi

  echo "" >&2
  echo "Every candidate failed:" >&2
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
  echo "  --help, -h      Show this help message and exit."
  echo ""
  echo "Examples:"
  echo "  ./launch-kali.sh                     Create the instance (or report it already exists)"
  echo "  ./launch-kali.sh --dry-run           Preview what would be created, without creating anything"
  echo "  ./launch-kali.sh --delete-only       Delete the existing instance"
  echo "  ./launch-kali.sh --recreate          Delete and recreate the instance"
  echo "  ./launch-kali.sh --recreate --force  Delete and recreate without a confirmation prompt"
}

main() {
  local dry_run="false"
  local delete_only="false"
  local recreate="false"
  local force="false"

  local arg
  for arg in "$@"; do
    case "$arg" in
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
      *)
        echo "ERROR: unknown argument: $arg" >&2
        echo "Run with --help to see available options." >&2
        exit 1
        ;;
    esac
  done

  if [[ "$dry_run" == "true" && ( "$delete_only" == "true" || "$recreate" == "true" ) ]]; then
    echo "ERROR: --dry-run cannot be combined with --delete-only or --recreate." >&2
    exit 1
  fi

  if [[ "$delete_only" == "true" && "$recreate" == "true" ]]; then
    echo "ERROR: --delete-only and --recreate cannot be used together." >&2
    exit 1
  fi

  if ! command -v gcloud >/dev/null 2>&1; then
    echo "ERROR: gcloud CLI not found. Run this in Cloud Shell, or install the Google Cloud CLI first." >&2
    exit 1
  fi

  local project
  project=$(gcloud config get-value project 2>/dev/null)
  if [[ -z "$project" ]]; then
    echo "ERROR: No active gcloud project. Run 'gcloud config set project <your-project-id>' first." >&2
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
  image=$(resolve_kali_image)
  if [[ -z "$image" ]]; then
    echo "ERROR: Could not find the Kali image (project=$IMAGE_PROJECT, family=$IMAGE_FAMILY)." >&2
    echo "This usually means you're signed in to the wrong Google account — use the @gmail.com account you used to purchase class lab access (see Part 1 of the intro-to-gcp tutorial)." >&2
    exit 1
  fi
  echo "Found image: $image" >&2

  ensure_compute_api_enabled

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
    echo "Kali instance '$INSTANCE_NAME' created in $zone." >&2
    echo "Connect via SSH-in-browser:" >&2
    echo "  https://console.cloud.google.com/compute/instances?project=$project" >&2
    echo "  or run: gcloud compute ssh $INSTANCE_NAME --zone=$zone" >&2
    exit 0
  else
    exit 1
  fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
