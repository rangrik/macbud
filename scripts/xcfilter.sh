#!/bin/bash
# Compact xcodebuild output: show errors, warnings, test results and the final status only.
grep -E --line-buffered -i "error:|warning:|Test Case|Test Suite|passed|failed|BUILD SUCCEEDED|BUILD FAILED|TEST SUCCEEDED|TEST FAILED|✘|✔|◇|Executed" | grep -vE "ld: warning: ignoring duplicate libraries|appintentsmetadataprocessor" 
exit ${PIPESTATUS[0]}
