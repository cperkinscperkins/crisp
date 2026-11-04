#!/usr/bin/env bash
#
# pod-session.sh — Rent a RunPod pod, run ONE command against it, and always release it.
#
# Creates an on-demand pod through the RunPod REST v2 API, waits for SSH, arms a
# dead-man timer INSIDE the pod, runs your command (with {host} and {port} filled
# in), then stops and terminates the pod -- on success, on failure, on a timeout,
# on Ctrl-C, and on kill.  The pod is never left running by this script.
#
# Usage:
#   ./scripts/pod-session.sh --gpu "<GPU type id>" [options] -- <command> [args...]
#   ./scripts/pod-session.sh --cleanup     # terminate pods this script created and lost track of
#   ./scripts/pod-session.sh --list        # list every pod on the account (read-only)
#
# Options:
#   --gpu ID[,ID...]    GPU type id(s) from the catalog, e.g. "NVIDIA H100 80GB HBM3", "NVIDIA B200".
#                       Several ids are tried in order when one is out of stock; the cost
#                       ceiling printed up front uses the most expensive of them.
#   --cloud C           SECURE (default) or COMMUNITY
#   --image I           cu124 (default: runpod/pytorch 2.4.0, CUDA 12.4.1 devel, /usr/local/cuda-12.4)
#                       cu128 (runpod/pytorch torch 2.8.0, CUDA 12.8.1 -- needed for B200 / sm_100)
#                       or a full image reference
#   --max-minutes N     hard lifetime of the pod (default 120).  The dead-man inside the pod
#                       terminates it at N minutes even if this machine dies.  The command's
#                       own timeout is N minus boot time minus a 5 minute teardown reserve.
#   --disk GB           container disk (default 50).  No persistent volume is ever attached.
#   --boot-minutes N    how long to wait for RUNNING + SSH (default 15)
#   --ssh-key PATH      default ~/.ssh/id_ed25519 (must match a key registered on the account)
#   --no-deadman        run even if the dead-man cannot be armed (NOT recommended)
#   --test-deadman      self-test: arm the dead-man with --max-minutes, skip local teardown, and
#                       wait for the pod to remove itself.  Proves the dead-man works.
#   --dry-run           print the create request and the cost ceiling, create nothing
#
# The command runs on THIS machine.  {host} and {port} in any argument are replaced with the
# pod's direct SSH endpoint, so the existing scripts work unchanged:
#
#   ./scripts/pod-session.sh --gpu "NVIDIA H100 80GB HBM3" --max-minutes 90 -- \
#       bash -c 'scripts/bench-on-pod.sh {host} {port} main ~/.ssh/id_ed25519 --bench=matmul &&
#                scripts/pull-runpod-results.sh {host} {port}'
#
# The command's output goes to put_temp_files_here/pod-session/<pod-name>.run.log, NOT to the
# terminal (suite logs are huge); the last lines are printed at the end.
#
# Requires: RUNPOD_API_KEY in the environment, curl, node (for JSON), ssh, timeout.
#
# Teardown order matches the console habit: Stop, then Terminate.  Terminate is attempted even
# if Stop fails, and success is only reported after the API confirms the pod is gone.  Every pod
# this script creates is recorded in put_temp_files_here/pod-session/active-pods.txt until it is
# confirmed gone, so `--cleanup` can always find it.
#
# Run it from Claude Code with run_in_background: a tool timeout kills with no chance to clean
# up (the dead-man and --cleanup still cover that case, but the trap is the first line).

set -u
set -o pipefail

API="https://api.runpod.io/v2"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_DIR="${REPO_DIR}/put_temp_files_here/pod-session"
STATE_FILE="${STATE_DIR}/active-pods.txt"
TEARDOWN_RESERVE_SECS=300

GPU=""
CLOUD="SECURE"
IMAGE="cu124"
MAX_MINUTES=120
DISK=50
BOOT_MINUTES=15
SSH_KEY="${HOME}/.ssh/id_ed25519"
NO_DEADMAN=0
TEST_DEADMAN=0
DRY_RUN=0
MODE="run"
CMD=()

POD_ID=""
POD_NAME=""
CREATE_ATTEMPTED=0
CHILD_PID=""
CLEANED_UP=0
START_EPOCH=$(date +%s)

# --- Logging -----------------------------------------------------------------------------
log()  { printf '[pod-session %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
warn() { printf '[pod-session %s] WARNING: %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die()  { printf '[pod-session %s] ERROR: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# --- Arguments ---------------------------------------------------------------------------
while [ $# -gt 0 ]; do
    case "$1" in
        --gpu)          GPU="${2:?--gpu needs a value}"; shift 2 ;;
        --cloud)        CLOUD="${2:?--cloud needs a value}"; shift 2 ;;
        --image)        IMAGE="${2:?--image needs a value}"; shift 2 ;;
        --max-minutes)  MAX_MINUTES="${2:?--max-minutes needs a value}"; shift 2 ;;
        --disk)         DISK="${2:?--disk needs a value}"; shift 2 ;;
        --boot-minutes) BOOT_MINUTES="${2:?--boot-minutes needs a value}"; shift 2 ;;
        --ssh-key)      SSH_KEY="${2:?--ssh-key needs a value}"; shift 2 ;;
        --no-deadman)   NO_DEADMAN=1; shift ;;
        --test-deadman) TEST_DEADMAN=1; shift ;;
        --dry-run)      DRY_RUN=1; shift ;;
        --cleanup)      MODE="cleanup"; shift ;;
        --list)         MODE="list"; shift ;;
        --)             shift; CMD=("$@"); break ;;
        *)              die "unknown argument: $1 (see the header of $0)" ;;
    esac
done

case "$IMAGE" in
    cu124) IMAGE="runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04"; MIN_CUDA="12.4" ;;
    cu128) IMAGE="runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404";          MIN_CUDA="12.8" ;;
    *)     MIN_CUDA="" ;;
esac

[ -n "${RUNPOD_API_KEY:-}" ] || die "RUNPOD_API_KEY is not set"
command -v curl    >/dev/null || die "curl not found"
command -v node    >/dev/null || die "node not found (used to read JSON)"
command -v timeout >/dev/null || die "timeout not found"
mkdir -p "$STATE_DIR"
TMP_DIR="$(mktemp -d "${STATE_DIR}/tmp.XXXXXX")" || die "cannot create a temp dir"

# --- HTTP + JSON helpers -----------------------------------------------------------------
# api METHOD PATH [BODY-FILE] -- body to $TMP_DIR/resp.json, status code to $HTTP_CODE.
# Never retries on its own: callers decide, because a retried create could rent twice.
HTTP_CODE=""
api() {
    local method="$1" path="$2" body="${3:-}"
    local args=(-sS --max-time 30 -X "$method" -o "${TMP_DIR}/resp.json" -w '%{http_code}'
                -H "Authorization: Bearer ${RUNPOD_API_KEY}" -H "Content-Type: application/json")
    [ -n "$body" ] && args+=(--data-binary "@${body}")
    HTTP_CODE="$(curl "${args[@]}" "${API}${path}" 2>"${TMP_DIR}/curl.err")" || HTTP_CODE="000"
}

# jget EXPR [FILE] -- evaluate a JS expression over the parsed JSON `d`; prints "" for null.
jget() {
    local file="${2:-${TMP_DIR}/resp.json}"
    node -e '
        let d = null;
        try { d = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8")); } catch (e) {}
        let v; try { v = (new Function("d", "return (" + process.argv[1] + ")"))(d); } catch (e) { v = null; }
        process.stdout.write(v === null || v === undefined ? "" : String(v));
    ' "$1" "$file"
}

state_add()    { echo "${POD_ID} ${POD_NAME} $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$STATE_FILE"; }
state_remove() {
    [ -f "$STATE_FILE" ] || return 0
    grep -v "^${1} " "$STATE_FILE" > "${TMP_DIR}/state.new" || true
    mv "${TMP_DIR}/state.new" "$STATE_FILE"
}

# --- Teardown ----------------------------------------------------------------------------
# pod_gone ID -- 0 when the API says the pod no longer exists (404) or is TERMINATED.
pod_gone() {
    api GET "/pods/$1"
    [ "$HTTP_CODE" = "404" ] && return 0
    [ "$HTTP_CODE" = "200" ] && [ "$(jget 'd.status')" = "TERMINATED" ] && return 0
    return 1
}

# release_pod ID -- Stop, then Terminate, then confirm.  Bounded: a few minutes at most.
release_pod() {
    local id="$1" i status
    log "releasing pod ${id}: stop"
    for i in 1 2 3; do
        api POST "/pods/${id}/action" "${TMP_DIR}/stop.json"
        case "$HTTP_CODE" in
            200) break ;;
            404) log "pod ${id} already gone"; return 0 ;;
            409) log "stop not valid in the pod's current status (fine, terminating)"; break ;;
            *)   warn "stop attempt ${i} got HTTP ${HTTP_CODE}"; sleep $((i * 5)) ;;
        esac
    done
    # Wait (bounded) for the stop to land before terminating, as in the console.
    for i in $(seq 1 12); do
        api GET "/pods/${id}"
        [ "$HTTP_CODE" = "404" ] && { log "pod ${id} already gone"; return 0; }
        status="$(jget 'd && d.status')"
        case "$status" in EXITED|TERMINATED|ERROR) break ;; esac
        sleep 10
    done
    log "releasing pod ${id}: terminate (status was ${status:-unknown})"
    for i in 1 2 3 4 5; do
        api POST "/pods/${id}/action" "${TMP_DIR}/terminate.json"
        case "$HTTP_CODE" in
            204|200|404) break ;;
            *) warn "terminate attempt ${i} got HTTP ${HTTP_CODE}"
               api DELETE "/pods/${id}"            # same thing, different route
               case "$HTTP_CODE" in 204|200|404) break ;; esac
               sleep $((i * 5)) ;;
        esac
    done
    for i in $(seq 1 12); do
        if pod_gone "$id"; then
            log "pod ${id} confirmed gone"
            state_remove "$id"
            return 0
        fi
        sleep 5
    done
    return 1
}

# find_by_name NAME -- ids of pods carrying NAME (for a create whose response was lost).
find_by_name() {
    api GET "/pods"
    [ "$HTTP_CODE" = "200" ] || return 1
    jget "(d.pods||[]).filter(p => p.name === '$1').map(p => p.id).join(' ')"
}

cleanup() {
    local rc=$?
    [ "$CLEANED_UP" = 1 ] && return
    CLEANED_UP=1
    trap '' INT TERM HUP          # a second Ctrl-C must not abort the teardown
    if [ -n "$CHILD_PID" ] && kill -0 "$CHILD_PID" 2>/dev/null; then
        log "stopping the running command (pid ${CHILD_PID})"
        kill -TERM "$CHILD_PID" 2>/dev/null; sleep 3; kill -KILL "$CHILD_PID" 2>/dev/null
    fi
    if [ "$TEST_DEADMAN" = 1 ] && [ -n "$POD_ID" ] && [ "$rc" = 0 ]; then
        rm -rf "$TMP_DIR"; exit 0   # the dead-man test already confirmed the pod is gone
    fi
    local ids="$POD_ID" failed=0 id
    if [ -z "$ids" ] && [ "$CREATE_ATTEMPTED" = 1 ]; then
        log "create response was lost; looking for a pod named ${POD_NAME}"
        ids="$(find_by_name "$POD_NAME")" || ids=""
    fi
    for id in $ids; do
        release_pod "$id" || failed=1
    done
    if [ -n "$ids" ]; then
        api GET "/pods"
        log "pods left on the account: $(jget "(d.pods||[]).map(p => p.id + ':' + p.status).join(' ') || 'none'")"
    fi
    if [ "$failed" = 1 ]; then
        printf '\n%s\n' "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        printf '%s\n'   "!!  POD ${ids} COULD NOT BE CONFIRMED TERMINATED -- IT MAY STILL BE BILLING" >&2
        printf '%s\n'   "!!  run: ./scripts/pod-session.sh --cleanup" >&2
        printf '%s\n'   "!!  or terminate it at https://console.runpod.io/pods" >&2
        printf '%s\n\n' "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!" >&2
        rc=3
    fi
    rm -rf "$TMP_DIR"
    exit "$rc"
}
trap cleanup EXIT
trap 'warn "interrupted"; exit 130' INT
trap 'warn "terminated";  exit 143' TERM
trap 'warn "hangup";      exit 129' HUP

echo '{"action":"stop"}'      > "${TMP_DIR}/stop.json"
echo '{"action":"terminate"}' > "${TMP_DIR}/terminate.json"

# --- --list / --cleanup ------------------------------------------------------------------
if [ "$MODE" = "list" ]; then
    api GET "/pods"
    [ "$HTTP_CODE" = "200" ] || die "list pods: HTTP ${HTTP_CODE}"
    jget "(d.pods||[]).map(p => p.id + '  ' + p.name + '  ' + p.status + '  ' + (p.gpu && p.gpu.id || '')).join('\n') || 'no pods'"
    echo
    exit 0
fi
if [ "$MODE" = "cleanup" ]; then
    [ -s "$STATE_FILE" ] || { log "no pods recorded in ${STATE_FILE}"; exit 0; }
    failed=0
    while read -r id name when; do
        [ -n "$id" ] || continue
        log "recorded pod ${id} (${name}, created ${when})"
        release_pod "$id" || { warn "pod ${id} not confirmed gone"; failed=1; }
    done < <(cat "$STATE_FILE")
    exit "$failed"
fi

# --- Run mode: validate ------------------------------------------------------------------
[ -n "$GPU" ] || die "--gpu is required (e.g. --gpu \"NVIDIA RTX A4000\")"
[ "${#CMD[@]}" -gt 0 ] || [ "$TEST_DEADMAN" = 1 ] || [ "$DRY_RUN" = 1 ] || die "no command after --"
[ -f "$SSH_KEY" ] || die "ssh key ${SSH_KEY} not found"
case "$CLOUD" in SECURE|COMMUNITY) ;; *) die "--cloud must be SECURE or COMMUNITY" ;; esac
[ "$MAX_MINUTES" -ge 10 ] 2>/dev/null || [ "$TEST_DEADMAN" = 1 ] || die "--max-minutes must be at least 10"

# Prices from the catalog, so the cost ceiling is printed before anything is rented.
IFS=',' read -r -a GPUS <<< "$GPU"
CLOUD_LC="$(echo "$CLOUD" | tr 'A-Z' 'a-z')"
declare -A PRICES
MAX_PRICE=0
for g in "${GPUS[@]}"; do
    G_ENC="$(node -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$g")"
    api GET "/catalog/gpus/${G_ENC}"
    [ "$HTTP_CODE" = "200" ] || die "unknown GPU type '${g}' (HTTP ${HTTP_CODE}); see GET ${API}/catalog/gpus"
    p="$(jget "d.price && d.price['${CLOUD_LC}']")"
    [ -n "$p" ] && [ "$p" != "0" ] || die "'${g}' has no ${CLOUD} price in the catalog (not offered there)"
    PRICES["$g"]="$p"
    MAX_PRICE="$(node -e 'console.log(Math.max(+process.argv[1], +process.argv[2]))' "$MAX_PRICE" "$p")"
done
CEILING="$(node -e 'console.log((process.argv[1] * process.argv[2] / 60).toFixed(2))' "$MAX_PRICE" "$MAX_MINUTES")"

POD_NAME="crisp-$(date +%Y%m%d-%H%M%S)-$$"
# make_body GPU-ID -- the create request for one GPU type, into $TMP_DIR/create.json.
make_body() {
    node -e '
        const [name, image, gpu, cloud, disk, minCuda] = process.argv.slice(1);
        const body = { name, image, cloud, disk: Number(disk), ports: ["22/tcp"],
                       startSsh: true, startJupyter: false, gpu: { id: gpu, count: 1 } };
        if (minCuda) body.gpu.minCudaVersion = minCuda;
        // No "mounts" key: no persistent volume.  Checked again on the created pod.
        process.stdout.write(JSON.stringify(body));
    ' "$POD_NAME" "$IMAGE" "$1" "$CLOUD" "$DISK" "$MIN_CUDA" > "${TMP_DIR}/create.json"
}

log "pod ${POD_NAME}: ${GPU} (${CLOUD}), max ${MAX_MINUTES} min => at most \$${CEILING} of GPU time (at \$${MAX_PRICE}/hr)"
log "image ${IMAGE}, container disk ${DISK} GB, no persistent volume"
if [ "$DRY_RUN" = 1 ]; then
    make_body "${GPUS[0]}"
    log "dry run, create request: $(cat "${TMP_DIR}/create.json")"
    exit 0
fi

# --- Create ------------------------------------------------------------------------------
# A 4xx is a definite "no pod": out of stock moves on to the next GPU, anything else stops.
# A timeout or 5xx is ambiguous -- a pod may exist -- so cleanup searches for it by name.
LOG_FILE="${STATE_DIR}/${POD_NAME}.run.log"
for g in "${GPUS[@]}"; do
    make_body "$g"
    log "creating on ${g} at \$${PRICES[$g]}/hr"
    CREATE_ATTEMPTED=1
    api POST "/pods" "${TMP_DIR}/create.json"
    case "$HTTP_CODE" in
        200|201) break ;;
        4??)
            CREATE_ATTEMPTED=0
            cp "${TMP_DIR}/resp.json" "${STATE_DIR}/${POD_NAME}.create-error.json" 2>/dev/null
            MSG="$(jget 'd && (d.detail || d.message || d.error || JSON.stringify(d))' | head -c 300)"
            case "$MSG" in
                *"no longer any instances available"*) warn "${g}: out of stock; no pod created" ;;
                *) die "create refused: HTTP ${HTTP_CODE} ${MSG} (no pod was created)" ;;
            esac ;;
        *)
            die "create got HTTP ${HTTP_CODE}; a pod may or may not exist" ;;
    esac
done
[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "201" ] || die "no GPU in '${GPU}' is in stock; no pod was created"
POD_ID="$(jget 'd.id')"
[ -n "$POD_ID" ] || die "create returned no pod id"
state_add
log "created pod ${POD_ID}"

PERSIST="$(jget 'd.mounts && d.mounts.persistent ? JSON.stringify(d.mounts.persistent) : ""')"
[ -z "$PERSIST" ] || die "pod came up WITH a persistent volume (${PERSIST}); releasing it"

# --- Wait for RUNNING with a direct SSH endpoint -----------------------------------------
BOOT_DEADLINE=$(( $(date +%s) + BOOT_MINUTES * 60 ))
HOST=""; PORT=""
while :; do
    api GET "/pods/${POD_ID}"
    if [ "$HTTP_CODE" = "200" ]; then
        STATUS="$(jget 'd.status')"
        case "$STATUS" in
            EXITED|ERROR|TERMINATED) die "pod went ${STATUS} while booting" ;;
        esac
        HOST="$(jget 'd.ssh && d.ssh.direct && d.ssh.direct.host')"
        PORT="$(jget 'd.ssh && d.ssh.direct && d.ssh.direct.port')"
        [ "$STATUS" = "RUNNING" ] && [ -n "$HOST" ] && [ -n "$PORT" ] && break
    else
        warn "status poll got HTTP ${HTTP_CODE}"
    fi
    [ "$(date +%s)" -lt "$BOOT_DEADLINE" ] || die "pod not RUNNING with SSH after ${BOOT_MINUTES} min (last status ${STATUS:-unknown})"
    sleep 10
done
log "pod RUNNING, ssh root@${HOST} -p ${PORT}"

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes
          -o ServerAliveInterval=30 -p "$PORT" -i "$SSH_KEY")
while ! ssh "${SSH_OPTS[@]}" "root@${HOST}" true 2>/dev/null; do
    [ "$(date +%s)" -lt "$BOOT_DEADLINE" ] || die "sshd did not accept a login within ${BOOT_MINUTES} min"
    sleep 10
done
log "ssh is up"

# --- Arm the dead-man inside the pod -----------------------------------------------------
# It terminates the pod from the inside at MAX_MINUTES after arming, whatever happens here.
# It terminates rather than stops: a stopped container cannot run the terminate after it.
# The container's env (RUNPOD_POD_ID, the pod's API key) is not in an ssh session's env,
# so the timer reads it from /etc/rp_environment or from PID 1.
DEADMAN_SECS=$(( MAX_MINUTES * 60 ))
read -r -d '' DEADMAN_SH <<'EOF'
load_env() {
    if [ -f /etc/rp_environment ]; then . /etc/rp_environment; fi
    if [ -z "${RUNPOD_POD_ID:-}" ] && [ -r /proc/1/environ ]; then
        while IFS= read -r -d '' kv; do
            case "$kv" in RUNPOD_*=*) export "$kv" ;; esac
        done < /proc/1/environ
    fi
}
load_env
if [ "$1" = "check" ]; then
    command -v runpodctl >/dev/null || { echo "NO runpodctl"; exit 1; }
    [ -n "${RUNPOD_POD_ID:-}" ]     || { echo "NO RUNPOD_POD_ID"; exit 1; }
    [ -n "${RUNPOD_API_KEY:-}" ]    || { echo "NO RUNPOD_API_KEY"; exit 1; }
    echo "OK pod=${RUNPOD_POD_ID} $(runpodctl version 2>/dev/null || runpodctl --version 2>/dev/null | head -1)"
    exit 0
fi
sleep "$2"
echo "$(date -u) dead-man firing for ${RUNPOD_POD_ID}"
runpodctl remove pod "$RUNPOD_POD_ID" \
  || runpodctl pod delete "$RUNPOD_POD_ID" \
  || runpodctl pod remove "$RUNPOD_POD_ID" \
  || curl -sS -X DELETE -H "Authorization: Bearer ${RUNPOD_API_KEY}" "https://api.runpod.io/v2/pods/${RUNPOD_POD_ID}"
EOF

DEADMAN_ARMED=0
CHECK="$(printf '%s\n' "$DEADMAN_SH" | ssh "${SSH_OPTS[@]}" "root@${HOST}" \
         'cat > /root/crisp-deadman.sh && bash /root/crisp-deadman.sh check 0' 2>&1)"
if [ "${CHECK%% *}" = "OK" ]; then
    if ssh "${SSH_OPTS[@]}" "root@${HOST}" \
         "nohup setsid bash /root/crisp-deadman.sh fire ${DEADMAN_SECS} > /root/crisp-deadman.log 2>&1 < /dev/null & echo \$! > /root/crisp-deadman.pid; sleep 1; kill -0 \$(cat /root/crisp-deadman.pid)"; then
        DEADMAN_ARMED=1
        log "dead-man armed: pod terminates itself in ${MAX_MINUTES} min (${CHECK})"
    fi
fi
if [ "$DEADMAN_ARMED" = 0 ]; then
    if [ "$NO_DEADMAN" = 1 ]; then
        warn "dead-man NOT armed (${CHECK}); continuing because of --no-deadman"
    else
        die "dead-man could not be armed (${CHECK}); refusing to run without it"
    fi
fi

# --- --test-deadman: leave the pod to the timer and watch it go --------------------------
if [ "$TEST_DEADMAN" = 1 ]; then
    log "dead-man test: NOT tearing down; waiting for the pod to remove itself"
    WAIT_DEADLINE=$(( $(date +%s) + DEADMAN_SECS + 600 ))
    while [ "$(date +%s)" -lt "$WAIT_DEADLINE" ]; do
        sleep 30
        if pod_gone "$POD_ID"; then
            log "DEAD-MAN TEST PASSED: pod ${POD_ID} removed itself after $(( ($(date +%s) - START_EPOCH) / 60 )) min"
            state_remove "$POD_ID"
            exit 0
        fi
    done
    die "DEAD-MAN TEST FAILED: pod still present 10 min past the timer"
fi

# --- Run the command ---------------------------------------------------------------------
RUN_SECS=$(( START_EPOCH + MAX_MINUTES * 60 - TEARDOWN_RESERVE_SECS - $(date +%s) ))
[ "$RUN_SECS" -gt 60 ] || die "boot used up the time budget; raise --max-minutes"
SUBST=()
for a in "${CMD[@]}"; do
    a="${a//\{host\}/$HOST}"; a="${a//\{port\}/$PORT}"
    SUBST+=("$a")
done
log "running (limit $(( RUN_SECS / 60 )) min, output in ${LOG_FILE}): ${SUBST[*]}"
# Background + wait, so a TERM to this script interrupts the wait and the trap runs now,
# not after the command finishes.
timeout --kill-after=30 "$RUN_SECS" "${SUBST[@]}" > "$LOG_FILE" 2>&1 < /dev/null &
CHILD_PID=$!
wait "$CHILD_PID"
RC=$?
CHILD_PID=""
case "$RC" in
    0)   log "command succeeded" ;;
    124) warn "command hit the ${RUN_SECS}s limit" ;;
    *)   warn "command exited ${RC}" ;;
esac
log "last lines of ${LOG_FILE}:"
tail -n 15 "$LOG_FILE" | sed 's/^/    | /'
exit "$RC"
