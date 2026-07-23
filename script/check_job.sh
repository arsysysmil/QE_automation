#!/bin/bash

set -euo pipefail

OUTPUT="${1:-}"

if [[ $# -ne 1 ]]; then
    echo "Usage:"
    echo "./check_job.sh output.out"
    exit 1
fi

if [[ ! -f "$OUTPUT" ]]; then
    echo "ERROR: $OUTPUT not found."
    exit 1
fi

if grep -q "JOB DONE." "$OUTPUT"; then
    echo "SUCCESS : $OUTPUT"
    exit 0
else
    echo "FAILED  : $OUTPUT"
    exit 1
fi
