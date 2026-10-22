#!/bin/bash
cd "$(dirname "$0")"
pkill -x TrashRescue 2>/dev/null; sleep 1
./build.sh 2>&1 | tee build.log
{
  echo "== listlocalsnapshots"; date
  /usr/bin/tmutil listlocalsnapshots / 2>&1
  echo "== destinationinfo"; date
  /usr/bin/tmutil destinationinfo 2>&1
  date
} > diag.log 2>&1 &
DPID=$!; sleep 10; kill $DPID 2>/dev/null && echo "tmutil TIMED OUT" >> diag.log
echo; echo "Done. You can close this window."
