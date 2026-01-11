#!/bin/sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"

mkdir -p "$DATA_DIR"

# Ensure the mounted volume is writable by the app user.
# (Named volumes default to root ownership.)
chown -R app:app "$DATA_DIR"

exec su-exec app /worker
