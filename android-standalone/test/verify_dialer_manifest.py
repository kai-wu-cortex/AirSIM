#!/usr/bin/env python3
import sys
import xml.etree.ElementTree as ET


ANDROID = "{http://schemas.android.com/apk/res/android}"
root = ET.fromstring(sys.stdin.read())

for activity in root.findall("./application/activity"):
    if activity.get(ANDROID + "name") != "com.airsim.phonecontrol.MainActivity":
        continue
    for intent_filter in activity.findall("intent-filter"):
        actions = {item.get(ANDROID + "name") for item in intent_filter.findall("action")}
        categories = {item.get(ANDROID + "name") for item in intent_filter.findall("category")}
        if ("android.intent.action.DIAL" in actions
                and "android.intent.category.DEFAULT" in categories
                and not intent_filter.findall("data")):
            sys.exit(0)

print("FAIL: built Standalone APK lacks the generic ACTION_DIAL filter required for ROLE_DIALER", file=sys.stderr)
sys.exit(1)
