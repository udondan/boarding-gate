#!/usr/bin/env bash
# Fails unless every line of wait.sh is covered, and lists the lines that
# aren't. Reads coverage/coverage.xml, written by
# `bundle exec bashcov -- test/coverage.sh`. bashcov ignores SimpleCov's
# minimum_coverage, so it is checked here. Codecov reports the coverage too,
# but it is no required check: it never reports on pull requests that skip
# the tests, which would then wait for it forever.
set -euo pipefail

report=${1:-coverage/coverage.xml}
if [ ! -f "$report" ]; then
  echo "::error::$report not found, run the tests with bashcov first."
  exit 1
fi

# Cobertura: <line number="12" hits="0"/> for each line that never ran.
uncovered=$(sed -nE 's/.*<line number="([0-9]+)" hits="0".*/\1/p' "$report" | sort -nu)
if [ -n "$uncovered" ]; then
  for line in $uncovered; do
    echo "::error file=wait.sh,line=$line::Line $line of wait.sh is not covered by the tests."
  done
  echo "Coverage of wait.sh is below 100%, see the lines above."
  exit 1
fi
echo "Every line of wait.sh is covered."
