#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
export JAVA_HOME=${JAVA_HOME:-/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home}
export ANDROID_HOME=${ANDROID_HOME:-$HOME/Library/Android/sdk}
export PASSPORT_BUILD_PYTHON=${PASSPORT_BUILD_PYTHON:-/opt/homebrew/opt/python@3.13/bin/python3.13}
exec ./gradlew --no-daemon "${@:-assembleDebug}"
