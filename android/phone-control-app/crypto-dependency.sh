#!/bin/sh
set -eu
AIRSIM_CRYPTO_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/build/dependencies
AIRSIM_CRYPTO_JAR="$AIRSIM_CRYPTO_DIR/bcprov-jdk15to18-1.84.jar"
mkdir -p "$AIRSIM_CRYPTO_DIR"
if [ ! -f "$AIRSIM_CRYPTO_JAR" ]; then
  curl -fsSL --retry 2 \
    https://repo.maven.apache.org/maven2/org/bouncycastle/bcprov-jdk15to18/1.84/bcprov-jdk15to18-1.84.jar \
    -o "$AIRSIM_CRYPTO_JAR"
fi
if [ "$(shasum -a 256 "$AIRSIM_CRYPTO_JAR" | awk '{print $1}')" != \
  a30777eebbd44aa1713c14ee04547de1df63ef3e383e910ed210e1d0f2c2ef92 ]; then
  echo 'Bouncy Castle dependency checksum mismatch' >&2
  exit 1
fi
printf '%s\n' "$AIRSIM_CRYPTO_JAR"
