#!/bin/bash
# submit.sh FILE GPU MODE LOG -- popcorn submit, waiting out the 6/hour rate limit.
P=/c/Users/cperk/Documents/crisp/contests/gpu-mode/bin/popcorn-cli.exe
for try in 1 2 3 4 5 6 7; do
  timeout 1900 $P submit "$1" --gpu "$2" --leaderboard matmul_v2 --mode "$3" --no-tui > "$4" 2>&1
  w=$(grep -oE 'Try again in [0-9]+s' "$4" | grep -oE '[0-9]+')
  if [ -z "$w" ]; then break; fi
  echo "rate limited, waiting ${w}s" >> "$4.wait"; sleep $((w + 15))
done
