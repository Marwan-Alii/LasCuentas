#!/usr/bin/env bash
# Sandbox-only runner (no Gradle/Maven access). On a normal machine use: ./gradlew :core:test
set -e; export PATH=$PATH:/home/claude/tools/kotlinc/bin; cd "$(dirname "$0")"
rm -rf build/main build/tmp build/test && mkdir -p build/tmp
kotlinc core/src/main/kotlin -d build/main 2>&1 | grep -v "^warning" || true
cp -r core/src/test/kotlin/. build/tmp/ && sed -i 's/kotlin\.test\./shimtest./' build/tmp/pk/hisab/core/*.kt
kotlinc -cp build/main:build/shim build/tmp -d build/test 2>&1 | grep -v "^warning" || true
java -cp build/main:build/shim:build/test:/home/claude/tools/kotlinc/lib/kotlin-stdlib.jar RunnerKt \
  pk.hisab.core.AllocationAndExpenseTest pk.hisab.core.LedgerTest pk.hisab.core.ReminderTest
