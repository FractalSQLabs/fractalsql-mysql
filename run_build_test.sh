#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 Daniel Gardiner d/b/a FractalSQLabs
#
# run_build_test.sh: containerized wrapper around build_test.sh.
# build_test.sh runs INSIDE docker/Dockerfile.test as a RUN step, so
# `docker build` succeeding IS the test passing, no separate
# `docker run` / cleanup dance needed.
#
# Usage:
#   ./run_build_test.sh                    # 8.4, 9.7, 26, sequential
#   ./run_build_test.sh --mysql 8.4        # one major only
#   ./run_build_test.sh 8.4 9 26           # explicit image tags
#   ./run_build_test.sh --mysql 8.4 --asan # ASan-instrumented (see
#   ./run_build_test.sh --mysql 8.4 --ubsan# docker/Dockerfile.test's
#                                           # FSQL_SAN_MODE build-arg)
#
# Prereqs: docker (with buildx).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [ -t 1 ]; then G="\033[32m"; R="\033[31m"; Z="\033[0m"; else G=""; R=""; Z=""; fi

SAN_MODE=""
ARGS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --asan)    SAN_MODE="asan" ;;
    --ubsan)   SAN_MODE="ubsan" ;;
    *)         ARGS+=("$1") ;;
  esac
  shift
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

if ! command -v docker >/dev/null 2>&1; then
  echo "ERROR: docker not on PATH." >&2
  exit 2
fi

# The values are the official docker image tags AND build_test.sh's
# scratch-path labels (datadir/socket/pid suffixes and port math,
# filesystem-safe either way), never version numbers handed to a MySQL
# binary:
#   "9"  = mysql:9, the 9.7 LTS image tag (mysql:9.0 exists but pins
#          the EOL 9.0 release)
#   "26" = mysql:26, the 26.7 image tag (currently 26.7.0; Oracle
#          publishes 26.x from the "26" tag, not a "26.7" tag)
MAJORS=(8.4 9 26)
if [ "${1:-}" = "--mysql" ]; then
  MAJORS=("$2")
elif [ $# -gt 0 ]; then
  MAJORS=("$@")
fi

FAILED=0
for v in "${MAJORS[@]}"; do
  echo ""
  echo "== docker build_test MySQL ${v} =="
  if docker build -f docker/Dockerfile.test \
       --build-arg "MYSQL_MAJOR=${v}" \
       --build-arg "FSQL_TEST_TIMEOUT_MULT=${FSQL_TEST_TIMEOUT_MULT:-1}" \
       --build-arg "FSQL_SAN_MODE=${SAN_MODE}" \
       -t "fractalsql-mysql-test:mysql${v}${SAN_MODE:+-$SAN_MODE}" \
       . ; then
    printf "  [${G}PASS${Z}] MySQL %s\n" "$v"
  else
    printf "  [${R}FAIL${Z}] MySQL %s\n" "$v"
    FAILED=1
  fi
done

echo ""
if [ "$FAILED" -eq 0 ]; then printf "${G}run_build_test: PASS${Z}\n"; exit 0
else printf "${R}run_build_test: FAIL${Z}\n"; exit 1
fi