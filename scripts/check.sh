#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
node --check frontend/app.js
go test ./internal/apidog -run 'Test(RequestFlow|ResponseAndCancel|CurlImport|ScriptAuthentication|WorkspaceCompatibility)$'
