#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
cleanup() {
  rm -rf -- "${TEST_DIR}"
}
trap cleanup EXIT

assert_rejected_api() {
  local api_url=$1
  local status

  set +e
  WARP_API_BASE_URL="${api_url}" \
    "${PROJECT_DIR}/src/generate-warp-config" "${TEST_DIR}/invalid.conf" \
    >/dev/null 2>"${TEST_DIR}/error.log"
  status=$?
  set -e
  if [[ ${status} -ne 65 ]]; then
    echo "expected invalid API URL to exit 65, got ${status}" >&2
    sed -n '1,5p' "${TEST_DIR}/error.log" >&2
    exit 1
  fi
}

assert_rejected_api "http://mirror.example/v0i1909051800"
assert_rejected_api "https://mirror.example/api?target=other"
assert_rejected_api "https://mirror.example:99999/api"

if [[ -e ${TEST_DIR}/invalid.conf ]]; then
  echo "invalid API URL unexpectedly produced a config" >&2
  exit 1
fi

echo "Generator wrapper tests passed"
