#!/usr/bin/env bash
#
# setup-third-party.sh — provision the PEER benchmark libraries.
#
# Crisp's benchmark ladder compares against three contender classes: a Control (a hand-written
# kernel), a Ceiling (a closed vendor library: cuBLAS / oneMKL), and a PEER — a composable
# template library you write kernels with, which is the same claim-space Crisp is in.  The peers
# are the yardstick that answers "is 77% of cuBLAS good?", and a Ceiling alone cannot answer it.
#
#   NVIDIA : CUTLASS      https://github.com/NVIDIA/cutlass
#   Intel  : SYCL-TLA     https://github.com/intel/sycl-tla    (CUTLASS 3.x ported to Xe)
#
# WHY THIS SCRIPT EXISTS.  Before 2026-08-22 neither library was provisioned by anything, and the
# two were located by DIFFERENT and undocumented mechanisms:
#
#   SYCL-TLA   <repo>/third_party/sycl-tla        (repo-relative; third_party/ is gitignored)
#   CUTLASS    -I/workspace/cutlass/include       (ABSOLUTE, and specific to one RunPod volume)
#
# Nothing created either path.  On a fresh pod the CUTLASS include therefore did not exist, the
# contender fell into its "headers not found" branch, and — because that stub exited 0 and a
# `_is_peer` substring bug matched "CUB" inside "CUBLAS" — the published report asserted CUTLASS
# had been measured and matched cuBLAS EXACTLY at every size, on hardware where it never ran.
# Both bugs are fixed; this script removes the underlying cause.
#
# Usage:
#   ./scripts/setup-third-party.sh                 # both, as needed for this machine
#   ./scripts/setup-third-party.sh cutlass         # just one
#   ./scripts/setup-third-party.sh --check         # report what is present, change nothing
#   CUTLASS_REF=v3.5.1 ./scripts/setup-third-party.sh cutlass     # pin a revision
#
# Idempotent: an existing checkout is left alone and reported, never silently re-cloned or reset.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TP="${REPO_ROOT}/third_party"

CUTLASS_URL="${CUTLASS_URL:-https://github.com/NVIDIA/cutlass.git}"
SYCL_TLA_URL="${SYCL_TLA_URL:-https://github.com/intel/sycl-tla.git}"

# REVISIONS ARE NOT PINNED BY DEFAULT, DELIBERATELY, AND THAT IS A TRADE-OFF WORTH NAMING.
# A hardcoded tag that turns out not to exist fails every fresh pod until someone edits this
# file; tracking the default branch always works but makes historical comparisons meaningless.
# The compromise: clone the default branch, then RECORD the resolved SHA in third_party/
# versions.txt so a past run's peer version is recoverable after the fact.  Set CUTLASS_REF /
# SYCL_TLA_REF to pin once a known-good revision is established — and do, before publishing a
# peer comparison anyone will quote.
CUTLASS_REF="${CUTLASS_REF:-}"
SYCL_TLA_REF="${SYCL_TLA_REF:-}"

LOCK="${TP}/versions.txt"

info() { printf '  %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Each entry: name | url | ref | a path that MUST exist afterwards (proves the clone is usable)
probe_path() {
    case "$1" in
        cutlass)  echo "include/cutlass/cutlass.h" ;;
        sycl-tla) echo "include/cutlass/cutlass.h" ;;
        *)        echo "" ;;
    esac
}

url_for() { case "$1" in cutlass) echo "$CUTLASS_URL";; sycl-tla) echo "$SYCL_TLA_URL";; esac; }
ref_for() { case "$1" in cutlass) echo "$CUTLASS_REF";; sycl-tla) echo "$SYCL_TLA_REF";; esac; }

report_one() {
    local name="$1" dir="${TP}/$1"
    if [ -d "$dir/.git" ]; then
        local sha; sha="$(git -C "$dir" rev-parse --short HEAD 2>/dev/null || echo '?')"
        local desc; desc="$(git -C "$dir" describe --tags --always 2>/dev/null || echo '?')"
        info "$(printf '%-10s present   %s (%s)' "$name" "$sha" "$desc")"
    else
        info "$(printf '%-10s ABSENT' "$name")"
    fi
}

fetch_one() {
    local name="$1" dir="${TP}/$1" url ref probe
    url="$(url_for "$name")"; ref="$(ref_for "$name")"; probe="$(probe_path "$name")"

    if [ -d "$dir/.git" ]; then
        info "$name already present — leaving it alone (delete ${dir} to re-provision)"
    else
        info "cloning $name from $url ${ref:+(ref $ref)} ..."
        mkdir -p "$TP"
        # Shallow by default: these are large and we only need headers.  A pinned ref needs the
        # full history to be resolvable, so only go shallow when tracking the default branch.
        if [ -n "$ref" ]; then
            git clone --quiet "$url" "$dir" || die "clone of $name failed"
            git -C "$dir" checkout --quiet "$ref" || die "$name has no revision '$ref'"
        else
            git clone --quiet --depth 1 "$url" "$dir" || die "clone of $name failed"
        fi
    fi

    # A clone that succeeded but does not contain the headers we compile against is worse than
    # no clone at all — it fails later, at a confusing place.  Check here, loudly.
    if [ -n "$probe" ] && [ ! -f "$dir/$probe" ]; then
        die "$name checked out but $probe is missing — wrong repository, or a ref without headers"
    fi
    info "$name OK"
}

write_lock() {
    mkdir -p "$TP"
    {
        echo "# Peer library revisions actually in use.  Written by scripts/setup-third-party.sh."
        echo "# third_party/ is gitignored, so THIS FILE is the only record of what a benchmark"
        echo "# run compared against.  Quote it alongside any published peer number."
        echo "# generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        for n in cutlass sycl-tla; do
            if [ -d "${TP}/$n/.git" ]; then
                printf '%-10s %s  %s\n' "$n" \
                    "$(git -C "${TP}/$n" rev-parse HEAD)" \
                    "$(git -C "${TP}/$n" describe --tags --always 2>/dev/null || echo '-')"
            fi
        done
    } > "$LOCK"
    info "recorded revisions in third_party/versions.txt"
}

WANT=()
CHECK_ONLY=0
for a in "$@"; do
    case "$a" in
        --check)  CHECK_ONLY=1 ;;
        cutlass|sycl-tla) WANT+=("$a") ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) die "unknown argument '$a' (expected: cutlass, sycl-tla, --check)" ;;
    esac
done

if [ "$CHECK_ONLY" = "1" ]; then
    echo "=== third_party status (${TP}) ==="
    report_one cutlass
    report_one sycl-tla
    [ -f "$LOCK" ] && { echo "--- versions.txt ---"; sed 's/^/  /' "$LOCK"; }
    exit 0
fi

# No explicit selection: provision what THIS machine can actually use.  Cloning CUTLASS onto an
# Intel-only box (or vice versa) wastes a large download for a contender that will never run.
if [ "${#WANT[@]}" -eq 0 ]; then
    command -v nvcc >/dev/null 2>&1 && WANT+=("cutlass")
    command -v icpx >/dev/null 2>&1 && WANT+=("sycl-tla")
    if [ "${#WANT[@]}" -eq 0 ]; then
        info "neither nvcc nor icpx found — provisioning BOTH (specify one to narrow)"
        WANT=(cutlass sycl-tla)
    fi
fi

echo "=== provisioning peer libraries into ${TP} ==="
for n in "${WANT[@]}"; do fetch_one "$n"; done
write_lock
echo "=== done ==="
