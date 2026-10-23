#!/bin/sh
# Instala las dependencias de Paralelo en macOS (Apple Silicon) con Homebrew.
set -e

if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "Paralelo necesita un Mac con Apple Silicon." >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Instala Homebrew primero: https://brew.sh" >&2
    exit 1
fi

brew install qemu swtpm

if [ "$1" = "--freerdp" ]; then
    brew install freerdp
fi

echo
echo "Dependencias instaladas."
echo "Para Coherence instala también \"Windows App\" de Microsoft desde la App Store,"
echo "o ejecuta este script con --freerdp para usar FreeRDP."
