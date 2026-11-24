#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p .build/check
swiftc -module-cache-path .build/check/modules \
  Sources/ApiDog/HTTP.swift Sources/ApiDog/Workspace.swift \
  Sources/ApiDog/RequestDraft.swift Sources/ApiDog/CurlCommand.swift \
  Sources/ApiDog/AuthFields.swift Sources/ApiDog/AuthScript.swift Tests/Checks.swift \
  -o .build/check/ApiDogChecks
.build/check/ApiDogChecks
