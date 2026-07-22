#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")"
exec swift run -c release speedocr "$@"
