#!/usr/bin/env bash
#
# 159-pod.sh — launch / check / pull an endeavour-159 pod run, WITHOUT holding the connection.
#
# WHY THIS REPLACES `ssh host 'bash scripts/159-pod-batch.sh'`.
# That form keeps the SSH connection open for the entire run, which has two failure modes and both
# bit on 2026-08-30:
#
#   * A dropped connection SIGHUPs the remote script.  A network blip mid-sweep silently kills the
#     work, and the pod keeps billing while nothing runs.
#   * The only completion signal is the ssh call returning.  When that notification did not
#     arrive, the batch had actually finished 25 minutes earlier and the H100 sat idle on the
#     user's money.  An ssh return proves the CONNECTION ended, never that the work did.
#
# So: launch detached, and treat a SENTINEL FILE as the only evidence of completion.  `status` is
# a few bytes over a fresh connection, cheap enough to check occasionally; `pull` brings the
# artifacts back and puts the result JSONs where the report generator actually reads them.
#
#   ./scripts/159-pod.sh launch <host> <port> [key] [SMOKE=1]
#   ./scripts/159-pod.sh status <host> <port> [key]
#   ./scripts/159-pod.sh pull   <host> <port> [key]
#
set -uo pipefail

CMD="${1:?usage: $0 {launch|status|pull} <host> <port> [ssh-key] [SMOKE=1]}"
HOST="${2:?host required}"
PORT="${3:?port required}"
KEY="${4:-$HOME/.ssh/id_ed25519}"
SMOKE_ARG="${5:-}"

REPO_REMOTE="/root/crisp"
OUT_REMOTE="$REPO_REMOTE/put_temp_files_here/159-pod"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SSH="ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=20 -i $KEY -p $PORT root@$HOST"

case "$CMD" in

  launch)
    SMOKE_ENV=""
    case "$SMOKE_ARG" in SMOKE=1|smoke|--smoke) SMOKE_ENV="SMOKE=1" ;; esac
    echo "launching${SMOKE_ENV:+ (SMOKE)} on $HOST:$PORT ..."
    # setsid + nohup + closed stdio: the batch outlives this connection entirely.
    $SSH "cd $REPO_REMOTE && rm -f $OUT_REMOTE/DONE && \
          setsid nohup env PATH=/usr/local/cuda/bin:\$PATH $SMOKE_ENV \
          bash scripts/159-pod-batch.sh > /tmp/159batch.log 2>&1 < /dev/null & \
          sleep 2; echo launched pid=\$!"
    echo
    echo "detached.  the connection can drop freely now."
    echo "check with:  ./scripts/159-pod.sh status $HOST $PORT"
    ;;

  status)
    # Deliberately tiny: the sentinel, the current step, and whether anything is still alive.
    $SSH "cd $REPO_REMOTE 2>/dev/null || exit 9; \
          if [ -f $OUT_REMOTE/DONE ]; then echo 'STATE: DONE'; cat $OUT_REMOTE/DONE; \
          else echo 'STATE: RUNNING (no sentinel)'; fi; \
          echo \"step: \$(grep -oE '^\\[[0-9b/]+\\]' $OUT_REMOTE/SUMMARY.txt 2>/dev/null | tail -1)\"; \
          echo \"alive: \$(pgrep -c -f 159-pod-batch.sh 2>/dev/null || echo 0) batch, \
\$(pgrep -c -f 'bench.py|matmul.py|sbcl|nvcc' 2>/dev/null || echo 0) workers\""
    ;;

  pull)
    mkdir -p "$ROOT/put_temp_files_here/159-pod-results"
    echo "pulling logs + summary ..."
    if command -v rsync >/dev/null 2>&1; then
      rsync -az -e "ssh -i $KEY -p $PORT" \
            "root@$HOST:$OUT_REMOTE/" "$ROOT/put_temp_files_here/159-pod-results/"
      rsync -az -e "ssh -i $KEY -p $PORT" \
            "root@$HOST:$REPO_REMOTE/benchmarks/results/" "$ROOT/benchmarks/results/"
    else
      # rsync is absent in git-bash on Windows; scp is equivalent for a single pull.
      scp -q -i "$KEY" -P "$PORT" -r "root@$HOST:$OUT_REMOTE/." \
            "$ROOT/put_temp_files_here/159-pod-results/"
      scp -q -i "$KEY" -P "$PORT" -r "root@$HOST:$REPO_REMOTE/benchmarks/results/." \
            "$ROOT/benchmarks/results/"
    fi
    echo "result JSONs now in benchmarks/results: $(ls "$ROOT"/benchmarks/results/*.json 2>/dev/null | wc -l)"
    echo "logs + SUMMARY in put_temp_files_here/159-pod-results/"
    echo
    echo "NEXT (both local, no GPU needed):"
    echo "  python scripts/audit-bench-results.py --platform-substr H100"
    echo "  python scripts/crisp_bench/report.py --output benchmarks/REPORT.md"
    ;;

  *)
    echo "unknown command: $CMD (expected launch|status|pull)"; exit 2 ;;
esac
