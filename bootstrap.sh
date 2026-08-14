#!/usr/bin/env bash
set -Eeuo pipefail

readonly REPOSITORY_URL="https://github.com/Not-Config/awg-warp-guardian.git"
readonly INSTALL_DIR="/opt/awg-warp-guardian"

if ((EUID != 0)); then
  echo "Run the bootstrap as root (curl ... | sudo bash)." >&2
  exit 77
fi

install_git() {
  if command -v git >/dev/null 2>&1; then
    return
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "git is required and apt-get is unavailable." >&2
    exit 69
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates git
}

update_checkout() {
  local current_branch origin_url

  if [[ ! -e ${INSTALL_DIR} ]]; then
    git clone --depth 1 --branch main "${REPOSITORY_URL}" "${INSTALL_DIR}"
    return
  fi
  if [[ ! -d ${INSTALL_DIR}/.git ]]; then
    echo "${INSTALL_DIR} exists but is not an awg-warp-guardian git checkout." >&2
    echo "Move that directory aside and rerun the command." >&2
    exit 73
  fi

  origin_url=$(git -C "${INSTALL_DIR}" remote get-url origin)
  case "${origin_url}" in
    "${REPOSITORY_URL}"|https://github.com/Not-Config/awg-warp-guardian)
      ;;
    *)
      echo "Refusing to update an unexpected repository: ${origin_url}" >&2
      exit 73
      ;;
  esac
  current_branch=$(git -C "${INSTALL_DIR}" branch --show-current)
  if [[ ${current_branch} != main ]]; then
    echo "${INSTALL_DIR} is on branch '${current_branch}', expected 'main'." >&2
    exit 73
  fi
  if [[ -n $(git -C "${INSTALL_DIR}" status --porcelain) ]]; then
    echo "Local changes found in ${INSTALL_DIR}; refusing to overwrite them." >&2
    exit 73
  fi
  git -C "${INSTALL_DIR}" pull --ff-only origin main
}

run_installer() {
  if [[ -t 0 && -t 1 ]]; then
    exec "${INSTALL_DIR}/install.sh" "$@"
  fi
  if [[ -e /dev/tty ]] && (: </dev/tty) 2>/dev/null; then
    exec "${INSTALL_DIR}/install.sh" --tui "$@" </dev/tty >/dev/tty
  fi
  exec "${INSTALL_DIR}/install.sh" --no-tui "$@"
}

install_git
update_checkout
run_installer "$@"
