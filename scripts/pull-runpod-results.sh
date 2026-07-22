#!/bin/bash
# Pull benchmark result JSONs from a (transient) RunPod instance.
#
# Consistent with bench-on-pod.sh / run-on-pod.sh: raw <host> <port> [ssh-key] —
# no ~/.ssh/config alias and no known_hosts editing needed.  Host-key checking is
# StrictHostKeyChecking=accept-new (same as the other pod scripts); RunPod maps a
# unique SSH port per pod, so known_hosts entries stay distinct even when an IP is
# recycled.  (For zero known_hosts writes, swap in
# `-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null` here and in the
# sibling scripts.)
#
# Usage: ./pull-runpod-results.sh <host> <port> [ssh-key] [remote-dir]
#   <host>       pod IP           (e.g. 103.207.149.79)
#   <port>       pod SSH port     (e.g. 16881)
#   [ssh-key]    default: ~/.ssh/id_ed25519
#   [remote-dir] default: ~/crisp/benchmarks/results
#
# Example:
#   ./scripts/pull-runpod-results.sh 103.207.149.79 16881 ~/.ssh/id_ed25519

set -euo pipefail

HOST="${1:?Usage: $0 <host> <port> [ssh-key] [remote-dir]}"
PORT="${2:?Usage: $0 <host> <port> [ssh-key] [remote-dir]}"
SSH_KEY="${3:-$HOME/.ssh/id_ed25519}"
REMOTE_DIR="${4:-~/crisp/benchmarks/results}"

# Local results dir, resolved relative to THIS script so it works from any cwd.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="${SCRIPT_DIR}/../benchmarks/results"
mkdir -p "$LOCAL_DIR"

SCP_OPTS=(-o StrictHostKeyChecking=accept-new -P "$PORT" -i "$SSH_KEY")

echo "Pulling *.json from root@${HOST}:${REMOTE_DIR} -> ${LOCAL_DIR} ..."
if scp "${SCP_OPTS[@]}" "root@${HOST}:${REMOTE_DIR}/*.json" "$LOCAL_DIR/"; then
    echo "Successfully pulled results to ${LOCAL_DIR}."
else
    echo "Failed. Check the pod is up, the port/key are correct, and ${REMOTE_DIR}/*.json exists." >&2
    exit 1
fi
