#!/bin/sh
set -eu

REPO_URL="${REPO_URL:-https://github.com/Trentyn/broadcom-wl-bcm4331.git}"
REF="${REF:-}"
INSTALL_DIR="${INSTALL_DIR:-/tmp/broadcom-wl-bcm4331}"

log() {
    printf '%s\n' "==> $*"
}

die() {
    printf '%s\n' "Error: $*" >&2
    exit 1
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require_root_access() {
    if [ "$(id -u)" -eq 0 ]; then
        return
    fi

    if ! have sudo; then
        die "this installer needs root privileges. Install sudo or run as root."
    fi

    log "Checking sudo access"
    sudo -v
}

as_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    else
        die "this installer needs root privileges. Install sudo or run as root."
    fi
}

install_bootstrap_dependencies() {
    missing=""

    have git || missing="$missing git"
    have curl || missing="$missing curl"

    if [ -z "$missing" ]; then
        log "Bootstrap dependencies already installed."
        return
    fi

    log "Installing bootstrap dependencies:$missing"
    if have apt-get; then
        as_root apt-get update
        as_root apt-get install -y ca-certificates curl git
    elif have dnf; then
        as_root dnf install -y ca-certificates curl git-core
    else
        die "neither apt-get nor dnf was found. This installer supports Debian/Ubuntu and Fedora."
    fi
}

clone_or_update_repo() {
    if [ -d "$INSTALL_DIR/.git" ]; then
        log "Updating existing checkout in $INSTALL_DIR"
        git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
    else
        if [ -e "$INSTALL_DIR" ]; then
            die "$INSTALL_DIR already exists but is not a git checkout. Set INSTALL_DIR to another path."
        fi

        log "Cloning $REPO_URL into $INSTALL_DIR"
        git init -q "$INSTALL_DIR"
        git -C "$INSTALL_DIR" remote add origin "$REPO_URL"
    fi

    # Always switch the working tree to what was just fetched; a bare fetch
    # would leave an older checkout (and its install.sh) in place.
    log "Fetching ${REF:-latest}"
    git -C "$INSTALL_DIR" fetch --depth 1 origin "${REF:-HEAD}"
    git -C "$INSTALL_DIR" checkout -q --force --detach FETCH_HEAD
    log "Using commit $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
}

run_installer() {
    [ -f "$INSTALL_DIR/install.sh" ] || die "install.sh was not found in $INSTALL_DIR"

    log "Running Broadcom wl installer"
    as_root bash "$INSTALL_DIR/install.sh"
}

# Parse the whole script before running anything. With `curl | sh`, Fedora's
# sh (bash) reads the script from stdin as it goes, so a child process reading
# stdin could swallow the remaining lines. This also protects against running
# a truncated download.
main() {
    require_root_access
    install_bootstrap_dependencies
    clone_or_update_repo
    run_installer
}

main "$@"
