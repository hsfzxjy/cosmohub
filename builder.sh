#!/bin/bash

set -e

ROOT_DIR=$(cd $(dirname $0) && pwd)
WORK_DIR=$ROOT_DIR/o
mkdir -p $WORK_DIR
cd $WORK_DIR

function log() {
  echo "$@" >&2
}

GOPATH=$(go env GOPATH)
COSMOUP=$GOPATH/bin/cosmoup
log "Found cosmoup at" $COSMOUP
log $(go version)

[ -x "$COSMOUP" ] || go install github.com/hsfzxjy/cosmoup/cmd/cosmoup@latest

function bootstrap() {
  SHA256="f4ff13af65fcd309f3f1cfd04275996fb7f72a4897726628a8c9cf732e850193"
  URL="https://github.com/jart/cosmopolitan/releases/download/3.9.2/cosmocc-3.9.2.zip"

  if [ -d .cosmocc ]; then
    log ".cosmocc already exists."
    return
  fi

  if sha256sum cosmocc.zip 2>/dev/null | grep -q $SHA256; then
    log "cosmocc.zip already exists and is valid."
  else
    log "Downloading cosmocc.zip..."
    wget "$URL" -O cosmocc.zip
  fi

  unzip -q cosmocc.zip -d .cosmocc

  # old cosmocc toolchain requirement
  if [ ! -z ${GITHUB_ACTIONS+x} ]; then
    sudo -n cp -a .cosmocc/bin/ape-x86_64.elf /usr/bin/ape
    sudo -n sh -c "echo ':APE:M::MZqFpD::/usr/bin/ape:' >/proc/sys/fs/binfmt_misc/register"
  fi
}

function setup-cosmopolitan() {
  git clone --depth=10 https://github.com/hsfzxjy/cosmopolitan.git cosmopolitan || true
  cd cosmopolitan

  if ! git checkout $COSMO_HASH; then
    # Try to fetch origin master
    git fetch origin master
    git checkout $COSMO_HASH || exit 1
  fi
  mkdir -p .cosmocc
  ln -s "$PWD/../.cosmocc" .cosmocc/3.9.2 || true
  ln -s "$PWD/../.cosmocc" .cosmocc/current || true
  echo "echo Skip download cosmocc" >build/download-cosmocc.sh
}

function setup-gcc() {
  git clone https://github.com/hsfzxjy/cosmo-gcc-builder.git cosmo-gcc-builder || true
  cd cosmo-gcc-builder

  git fetch origin master
  git checkout origin/master || exit 1

  cp "$ROOT_DIR/cosmo-gcc-builder.cosmoup" root.cosmoup
  "$COSMOUP"
}

function pack() {
  OUT=$1
  IN=$2
  local OLD_SHA256=
  if [ ! -d "$IN" ]; then
    log "Directory $IN does not exist."
    exit 1
  fi
  if [ -f "$OUT" ]; then
    OLD_SHA256=$(sha256sum "$OUT" | awk '{print $1}')
  fi
  log "Packing $IN to $OUT"
  tar -czf "$OUT" --mtime='UTC 1970-01-01' -C "$IN" --owner 0 --group=0 --numeric-owner --sort=name .
  NEW_SHA256=$(sha256sum "$OUT" | awk '{print $1}')
  if [ ! -z "$OLD_SHA256" ] && [ "$OLD_SHA256" != "$NEW_SHA256" ]; then
    log "Warning: SHA256 mismatch for $OUT"
    log "Old: $OLD_SHA256"
    log "New: $NEW_SHA256"
  fi
  echo "o/$OUT"
}

function print_should_build_result() {
  if ! assets=$(gh release view "${COSMO_HASH}" --json assets --jq '.assets[].name'); then
    log "Release ${COSMO_HASH} does not exist."
    echo "true"
    exit 0
  fi
  for artifact in $@; do
    local file="$artifact.tgz"
    if ! echo "$assets" | grep -q "$file"; then
      log "Release ${COSMO_HASH} is missing asset $file."
      echo "true"
      exit 0
    fi
  done
  echo "false"
}

function get_cosmo_hash() {
  if [ -z "$COSMO_HASH" ]; then
    log "COSMO_HASH is not set. Using first item from specs/versions"
    COSMO_HASH=$(head -n 1 "$ROOT_DIR/specs/versions")
  fi
  log "Using COSMO_HASH=$COSMO_HASH"
}

function array_contains() {
  local array="$1[@]"
  local seeking=$2
  local in=1
  for element in ${!array}; do
    if [[ $element == $seeking ]]; then
      in=0
      break
    fi
  done
  return $in
}

function check_gcc_target_valid() {
  local target="$1"
  local all_targets=$(gcc_targets)
  if ! array_contains all_targets "$target"; then
    log "Unknown target: $target, available targets are:"
    log "$all_targets"
    exit 1
  fi
}

get_cosmo_hash
source "$ROOT_DIR/specs/$COSMO_HASH"

if [ "$1"x == "get-tag"x ]; then
  echo "$COSMO_HASH"
elif [ "$1"x == "prepare-cosmo"x ]; then
  bootstrap
  setup-cosmopolitan
elif [ "$1"x == "build-cosmo"x ]; then
  bootstrap
  setup-cosmopolitan
  bash tool/cosmoup/package.sh
elif [ "$1"x == "pack-cosmo"x ]; then
  OUTDIR="uploads/"
  COSMO_ARTIFACTS=$(cosmo_artifacts)
  # check if all artifacts exist
  mkdir -p "$OUTDIR"
  for x in $COSMO_ARTIFACTS; do
    IN="cosmopolitan/cosmoup/$x"
    OUT="$OUTDIR/cosmo-$x.tgz"
    pack "$OUT" "$IN"
  done
elif [ "$1"x == "should-build-cosmo"x ]; then
  COSMO_ARTIFACTS=()
  for x in $(cosmo_artifacts); do
    COSMO_ARTIFACTS+=("cosmo-$x")
  done
  print_should_build_result $COSMO_ARTIFACTS

# === GCC related commands ===
elif [ "$1"x == "prepare-gcc"x ]; then
  bootstrap
  setup-gcc
elif [ "$1"x == "build-gcc"x ]; then
  bootstrap
  setup-gcc
  target="$2"
  check_gcc_target_valid "$target"

  export C_INCLUDE_PATH=$WORK_DIR/.cosmocc/include/third_party/zlib
  export CPLUS_INCLUDE_PATH=$WORK_DIR/.cosmocc/include/third_party/zlib
  find o -name 'built.fat' -delete || true
  rm -rf results/
  shift
  make "$target"
elif [ "$1"x == "pack-gcc"x ]; then
  target="$2"
  check_gcc_target_valid "$target"

  OUTDIR="uploads/"
  mkdir -p "$OUTDIR"

  artifacts=$(get_gcc_artifacts "$target")
  for x in $artifacts; do
    IN="cosmo-gcc-builder/results/$x"
    OUT="$OUTDIR/$x.tgz"
    pack "$OUT" "$IN"
  done
elif [ "$1"x == "should-build-gcc"x ]; then
  target="$2"
  check_gcc_target_valid "$target"

  artifacts=$(get_gcc_artifacts "$target")
  print_should_build_result $artifacts

elif [ "$1"x == "gcc-targets"x ]; then
  jq -R -s -c '[scan("\\S+")]' < <(gcc_targets)
else
  log "Unknown command: $1"
  exit 1
fi
