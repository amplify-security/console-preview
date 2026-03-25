#!/bin/bash

set -e
if [ ! -z "$AMPLIFY_DEBUG" ]; then
  set -x
fi

REPOSITORY="amplify-security/console-preview"
DOWNLOAD_PATH="${XDG_CACHE_HOME:-$HOME/.cache}/amplify-console"
RELEASE_ARTIFACT="$DOWNLOAD_PATH/release.$(date +%s).json"
INSTALL_PATH="${XDG_BIN_HOME:-$HOME/.local/bin}"

# color codes for output messages
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() {
  local prefix="$1"
  shift

  for line in "$@"; do
    printf "$prefix %s\n" "$line"
  done
}

info() {
  log "${BLUE}##${NC}" "$@"
}

warning() {
  log "${YELLOW}!!${NC}" "$@"
}

success() {
  log "${GREEN}OK${NC}" "$@"
}

error() {
  log "${RED}!!${NC}" "$@" >&2
  exit 1
}

has_tool() {
  command -v "$1" &>/dev/null
}

clean_on_exit() {
  [ -f "$RELEASE_ARTIFACT" ] && rm -f "$RELEASE_ARTIFACT"
  [ -f "$DOWNLOAD_PATH/console-"* ] && rm -f "$DOWNLOAD_PATH/console-"*
}

detect_platform() {
  local os arch

  case "$(uname -s)" in
    Linux) os="linux" ;;
    Darwin) os="darwin" ;;
    *) error "Unsupported OS: $(uname -s)" ;;
  esac

  case "$(uname -m)" in
    x86_64 | amd64) arch="x64" ;;
    aarch64 | arm64) arch="arm64" ;;
    *) error "Unsupported architecture: $(uname -m)" ;;
  esac

  printf "${os}-${arch}"
}

download_artifact() {
  local artifact_url="$1"
  local output_path="$2"

  curl -fsSL -o "$output_path" "$artifact_url"
}

fetch_release() {
  local release_ref failed
  if [ -n "$1" ]; then
    release_ref="tags/$1"
  else
    release_ref="latest"
  fi

  local release_url="https://api.github.com/repos/$REPOSITORY/releases/$release_ref"
  curl -fs --header "Accept: application/vnd.github+json" \
    -o "$RELEASE_ARTIFACT" "$release_url" || failed=$?
  if [ -n "$failed" ]; then
    error "Couldn't fetch release information from GitHub. ($failed)" \
      "Please check your internet connection and try again."
  fi
}

get_version() {
  local version

  if has_tool jq; then
    version=$(jq -r '.tag_name' "$RELEASE_ARTIFACT")
  else
    version="$(
      grep -oP '"tag_name":\s*"\K[^"]+' "$RELEASE_ARTIFACT" ||
        error "grep fallback could not parse this release."
    )"
  fi

  printf "$version"
}

get_checksum() {
  local asset_name="$1"
  local digest

  if has_tool jq; then
    digest="$(jq -r --arg name "$asset_name" \
      '.assets[] | select(.name == $name) | .digest' \
      "$RELEASE_ARTIFACT")"
  else
    digest="$(grep -A 37 "\"name\": \"${asset_name}\"" "$RELEASE_ARTIFACT" | # さな〜
      grep -oP '"digest":\s*"\K[^"]+' |
      head -1)"
  fi

  if [ -z "$digest" ]; then
    error "Could not find a checksum for '$asset_name'."
  fi

  # Strip "sha256:" prefix
  printf "${digest#sha256:}"
}

verify_checksum() {
  local file="$1"
  local expected="$2"
  local actual

  case "$(uname -s)" in
    Linux) actual="$(sha256sum "$file" | awk '{print $1}')" ;;
    Darwin) actual="$(shasum -a 256 "$file" | awk '{print $1}')" ;;
    *) error "What are you trying to verify? 🤔" ;;
  esac

  if [ "$actual" != "$expected" ]; then
    error "Failed to validate checksum for the downloaded Console!" \
      "  Expected: $expected" \
      "    Actual: $actual" \
      "You may want to try again."
  fi
}

update_path() {
  local rc_file

  case ":$PATH:" in
    *":$INSTALL_PATH:"*) return 0 ;;
  esac

  case "$SHELL" in
    */bash) rc_file="$HOME/.bashrc" ;;
    */zsh) rc_file="$HOME/.zshrc" ;;
    *)
      warning "Unsupported shell detected: $SHELL." \ 
      "Please add $INSTALL_PATH to your PATH manually."
      ;;
  esac

  printf '\nexport PATH="%s:$PATH"\n' "$INSTALL_PATH" >>"$rc_file"
  info "Added $INSTALL_PATH to your PATH in $rc_file." \
    "You will need to restart your terminal or run 'source $rc_file' before starting Console."
}

install_console() {
  has_tool curl || error "curl was not found. Please install it before proceeding."

  local platform
  platform=$(detect_platform)
  info "Detected platform: $platform"

  info "Fetching release information"
  mkdir -p "$DOWNLOAD_PATH" "$INSTALL_PATH"
  fetch_release "$1"
  local version=$(get_version)
  success "This script will install Console version $version."

  local asset_name="console-$platform"
  local asset_url="https://github.com/$REPOSITORY/releases/download/$version/$asset_name"
  local output_path="$DOWNLOAD_PATH/console-$version"
  info "Downloading Console from $asset_url"
  download_artifact "$asset_url" "$output_path"

  local expected_checksum=$(get_checksum $asset_name)
  verify_checksum "$output_path" "$expected_checksum"
  success "Verified download integrity"

  info "Setting up Amplify Console"
  mv "$output_path" "$INSTALL_PATH/console"
  chmod +x "$INSTALL_PATH/console"
  update_path

  success "Installed Amplify Console successfully." \
    "Start a new interactive session using the 'console' command."

  info "Note that currently, you will need to manually configure an API key." \
    "Please reach out and refer to https://docs.amplify.security/installation for instructions."
}

trap clean_on_exit EXIT
install_console "$@"
