#!/bin/sh
set -eu
cd "$(dirname "$0")"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17 or newer}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export JAVA_HOME
sdk="$ANDROID_HOME/platforms/android-35/android.jar"
tools="$ANDROID_HOME/build-tools/35.0.0"
mkdir -p build/classes build/dex
"$JAVA_HOME/bin/javac" -source 17 -target 17 -cp "$sdk" -d build/classes src/*.java
"$JAVA_HOME/bin/jar" cf build/classes.jar -C build/classes .
"$tools/d8" --min-api 34 --lib "$sdk" --output build/dex build/classes.jar
"$tools/aapt2" link -I "$sdk" --manifest AndroidManifest.xml -o build/unsigned.apk
(cd build/dex && "$JAVA_HOME/bin/jar" uf ../unsigned.apk classes.dex)
"$tools/zipalign" -f 4 build/unsigned.apk build/f50-dsds-unsigned.apk
printf 'Built dsds-helper/build/f50-dsds-unsigned.apk; sign with a private local key before installation.\n'
