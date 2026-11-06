#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT
xcrun swiftc Shared/Todo.swift Shared/TodoIntegration.swift Shared/TodoStore.swift App/HandoffReader.swift App/LocalSources.swift App/TodoAutomaticUpdateStatus.swift Tests/PaymentWorkflow.swift Tests/PaymentRemoval.swift Tests/ManualAndPaging.swift Tests/main.swift -o "$build_dir/tests"
"$build_dir/tests" "$@"
