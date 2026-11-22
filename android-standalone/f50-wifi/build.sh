#!/bin/sh
set -eu
cd "$(dirname "$0")"
: "${ANDROID_HOME:=$HOME/Library/Android/sdk}"
: "${JAVA_HOME:?Set JAVA_HOME to JDK 17 or newer}"
export JAVA_HOME
sdk="$ANDROID_HOME/platforms/android-35/android.jar"
mkdir -p build/classes build/generated/com/airsim/f50wifi build/dex build/test
python3 - <<'PY'
import json
from pathlib import Path
html=Path('web/index.html').read_text()
# Multiple chunks avoid the JVM's constant-pool UTF8 size limit for translated pages.
chunks=[html[i:i+10000] for i in range(0,len(html),10000)]
source='package com.airsim.f50wifi; final class WebPage { static final String HTML=String.join("",new String[]{'+','.join(json.dumps(c,ensure_ascii=True) for c in chunks)+'}); }'
Path('build/generated/com/airsim/f50wifi/WebPage.java').write_text(source)
PY
"$JAVA_HOME/bin/javac" -source 17 -target 17 -cp "$sdk" -d build/classes src/*.java build/generated/com/airsim/f50wifi/WebPage.java
"$JAVA_HOME/bin/jar" cf build/classes.jar -C build/classes .
"$ANDROID_HOME/build-tools/35.0.0/d8" --min-api 34 --lib "$sdk" --output build/dex build/classes.jar
cp build/dex/classes.dex build/f50-wifi.dex
"$JAVA_HOME/bin/javac" -d build/test src/PortalRules.java src/CallSafeNetworkPolicy.java src/DualSimPolicy.java test/PortalRulesTest.java test/CallSafeNetworkPolicyTest.java test/DualSimPolicyTest.java
"$JAVA_HOME/bin/java" -cp build/test com.airsim.f50wifi.PortalRulesTest
"$JAVA_HOME/bin/java" -cp build/test com.airsim.f50wifi.CallSafeNetworkPolicyTest
"$JAVA_HOME/bin/java" -cp build/test com.airsim.f50wifi.DualSimPolicyTest
"$JAVA_HOME/bin/javac" -d build/test src/HotelProxy.java test/HotelProxyTest.java
"$JAVA_HOME/bin/java" -cp build/test com.airsim.f50wifi.HotelProxyTest
printf 'Built f50-wifi/build/f50-wifi.dex\n'
