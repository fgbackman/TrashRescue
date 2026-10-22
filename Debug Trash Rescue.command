#!/bin/bash
cd "$(dirname "$0")"
pkill -x TrashRescue 2>/dev/null; sleep 1
sw_vers > run.log 2>&1
swiftc --version >> run.log 2>&1
echo "== run" >> run.log
OS_ACTIVITY_DT_MODE=1 ./TrashRescue.app/Contents/MacOS/TrashRescue >> run.log 2>&1 &
P=$!; sleep 8
echo "== still running? $(ps -p $P -o pid= )" >> run.log
sample $P 2 -file sample.txt >/dev/null 2>&1
echo "Done."
