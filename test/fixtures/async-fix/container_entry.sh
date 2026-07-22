#!/bin/sh
set -eu

smoke_root="${TMPDIR:-/tmp}/async-fix-smoke"
honeycomb_root="$smoke_root/honeycomb"
hive_root="$smoke_root/hive"
bundle_root="$smoke_root/bundle"
bundle_log="$smoke_root/logs/bundle-install.log"

export HOME="$smoke_root/home"
export BUNDLE_APP_CONFIG="$smoke_root/bundle-config"
mkdir -p "$HOME" "$BUNDLE_APP_CONFIG" "$honeycomb_root" "$hive_root" "$smoke_root/logs" "$hive_root/vendor/cache"
tar -C /inputs/honeycomb --exclude=.git -cf - . | tar --no-same-owner -C "$honeycomb_root" -xf -
tar -C /inputs/hive --exclude=.git -cf - . | tar --no-same-owner -C "$hive_root" -xf -
cp /inputs/gem-cache/*.gem "$hive_root/vendor/cache/"

cd "$hive_root"
bundle config set --local path "$bundle_root" >/dev/null
if ! bundle install --local --jobs 4 >"$bundle_log" 2>&1; then
  cat "$bundle_log" >&2
  exit 1
fi

export ASYNC_FIX_REAL_GIT=/usr/bin/git
export HONEYCOMB_RUNTIME_ROOT="$honeycomb_root"
export HIVE_RUNTIME_ROOT="$hive_root"
export HIVE_BIN="$hive_root/bin/hive"
export HIVE_INVOKED_BIN="$hive_root/bin/hive"
export HIVE_CODEX_BIN="$honeycomb_root/test/fixtures/async-fix/bin/codex"

exec bundle exec ruby "$honeycomb_root/test/fixtures/async-fix/container_smoke.rb"
