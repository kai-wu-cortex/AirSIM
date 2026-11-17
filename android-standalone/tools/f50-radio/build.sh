#!/bin/sh
set -eu
cd "$(dirname "$0")"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17 or newer}"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
export JAVA_HOME
sdk="$ANDROID_HOME/platforms/android-35/android.jar"
mkdir -p build/classes build/dex
"$JAVA_HOME/bin/javac" --release 17 -cp "$sdk" -d build/classes F50RadioCheck.java
"$JAVA_HOME/bin/jar" cf build/classes.jar -C build/classes .
"$ANDROID_HOME/build-tools/35.0.0/d8" --min-api 34 --lib "$sdk" --output build/dex build/classes.jar
cp build/dex/classes.dex build/f50-radio-check.dex
