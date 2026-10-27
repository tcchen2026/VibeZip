#!/bin/bash
cd "$(dirname "$0")" || exit 1
./build.sh --open
STATUS=$?
if [ "$STATUS" -ne 0 ]; then
    echo
    echo "Build failed. See the errors above and README.md."
    read -r -p "Press Return to close."
fi
exit "$STATUS"
