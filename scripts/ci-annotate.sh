#!/bin/sh
# Turns compiler and XCTest errors in build logs into GitHub annotations, so failures
# show up on the run summary and through the checks API without opening the log.
# Usage: scripts/ci-annotate.sh build.log [more.log ...]
for log in "$@"; do
  [ -f "$log" ] || continue
  grep -E '^/[^:]+:[0-9]+(:[0-9]+)?: (error|warning): ' "$log" \
    | grep -v '/.build/checkouts/' \
    | sort -u \
    | head -n 40 \
    | sed -E \
        -e 's#^([^:]+):([0-9]+):([0-9]+): (error|warning): (.*)$#::\4 file=\1,line=\2,col=\3::\5#' \
        -e 's#^([^:]+):([0-9]+): (error|warning): (.*)$#::\3 file=\1,line=\2::\4#'
done
