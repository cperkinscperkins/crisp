#!/bin/bash
# script to pull benchmark results from runpod instance
# Usage: ./pull-runpod-results.sh <ssh-host-alias> [remote-dir]

if [ -z "$1" ]; then
    echo "Usage: $0 <ssh-host-alias> [remote-dir]"
    echo "Example: $0 my-runpod-h100 ~/crisp/benchmarks/results"
    exit 1
fi

HOST=$1
REMOTE_DIR=${2:-"~/crisp/benchmarks/results"}
LOCAL_DIR="../benchmarks/results"

mkdir -p "$LOCAL_DIR"

echo "Pulling results from $HOST:$REMOTE_DIR to $LOCAL_DIR..."
scp "$HOST:$REMOTE_DIR/*.json" "$LOCAL_DIR/"

if [ $? -eq 0 ]; then
    echo "Successfully pulled results."
else
    echo "Failed to pull results. Check SSH connection and remote path."
fi
