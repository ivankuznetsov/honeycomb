#!/usr/bin/env bash
set -euo pipefail

readonly expected_hive_revision="af22485f9b2bee27a7497dc138e5e58ab9725bde"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly script_dir
honeycomb_root="$(cd "$script_dir/../.." && pwd -P)"
readonly honeycomb_root
readonly hive_root="${1:-}"
readonly ruby_image="ruby@sha256:7a61aa7fe86768830f65d8e12571fc115f381a54557c7c88619a5368b92a0474"
readonly gem_cache="${ASYNC_FIX_GEM_CACHE:-$(ruby -e '
  user_cache = File.join(Gem.user_dir, "cache")
  print(File.directory?(user_cache) ? user_cache : File.join(Gem.dir, "cache"))
')}"
readonly container_name="honeycomb-async-fix-smoke-$$"
readonly docker_timeout_seconds="${ASYNC_FIX_DOCKER_TIMEOUT_SECONDS:-600}"

if [[ -z "$hive_root" ]]; then
  printf 'usage: %s /path/to/exact-clean-hive-checkout\n' "$0" >&2
  exit 64
fi

for checkout in "$honeycomb_root" "$hive_root"; do
  git -C "$checkout" rev-parse --is-inside-work-tree >/dev/null
done

honeycomb_revision="$(git -C "$honeycomb_root" rev-parse HEAD)"
readonly honeycomb_revision
hive_revision="$(git -C "$hive_root" rev-parse HEAD)"
readonly hive_revision
if [[ "$hive_revision" != "$expected_hive_revision" ]]; then
  printf 'async-fix smoke: Hive HEAD %s is not pinned revision %s\n' \
    "$hive_revision" "$expected_hive_revision" >&2
  exit 65
fi

checkout_status() {
  git -C "$1" status --porcelain=v1 --untracked-files=all
}

if [[ -n "$(checkout_status "$hive_root")" ]]; then
  printf 'async-fix smoke: Hive checkout must be clean\n' >&2
  exit 65
fi
if [[ "${ASYNC_FIX_SMOKE_ALLOW_DIRTY_HONEYCOMB:-0}" != "1" ]] && \
   [[ -n "$(checkout_status "$honeycomb_root")" ]]; then
  printf 'async-fix smoke: Honeycomb checkout must be clean\n' >&2
  exit 65
fi

check_index_flags() {
  git -C "$1" ls-files -v -f -z | ruby -e '
    hidden = STDIN.read.split("\0").find { |entry| !entry.empty? && entry.getbyte(0) != "H".ord }
    abort "non-default index flag: #{hidden.byteslice(0, 1).inspect}" if hidden
  '
}
check_index_flags "$honeycomb_root"
check_index_flags "$hive_root"

if [[ ! -d "$gem_cache" ]]; then
  printf 'async-fix smoke: offline gem cache not found: %s\n' "$gem_cache" >&2
  exit 66
fi
if ! docker image inspect "$ruby_image" >/dev/null 2>&1; then
  printf 'async-fix smoke: preloaded image required (no pull allowed): %s\n' "$ruby_image" >&2
  exit 66
fi

source_fingerprint() {
  {
    git -C "$1" rev-parse HEAD
    git -C "$1" symbolic-ref --quiet HEAD 2>/dev/null || printf 'DETACHED\n'
    git -C "$1" status --porcelain=v1 --untracked-files=all --ignored=matching
    git -C "$1" ls-files -s -z
    git -C "$1" ls-files -v -f -z
  } | sha256sum | cut -d' ' -f1
}

honeycomb_before="$(source_fingerprint "$honeycomb_root")"
readonly honeycomb_before
hive_before="$(source_fingerprint "$hive_root")"
readonly hive_before

input_root="$(mktemp -d "${TMPDIR:-/tmp}/honeycomb-async-fix-inputs.XXXXXX")"
readonly input_root
readonly cid_file="$input_root/container.cid"

snapshot_checkout() {
  local source="$1"
  local destination="$2"
  mkdir -p "$destination"
  git -C "$source" ls-files -z | \
    tar -C "$source" --null --files-from=- -cf - | \
    tar --no-same-owner -C "$destination" -xf -
}
snapshot_checkout "$honeycomb_root" "$input_root/honeycomb"
snapshot_checkout "$hive_root" "$input_root/hive"

# shellcheck disable=SC2329
cleanup() {
  local status=$?
  local cleanup_status=0
  local container_target="$container_name"
  trap - EXIT INT TERM
  set +e

  if [[ -s "$cid_file" ]]; then
    container_target="$(<"$cid_file")"
  fi
  if docker container inspect "$container_target" >/dev/null 2>&1; then
    /usr/bin/timeout --signal=TERM --kill-after=5s 20s \
      docker rm -f "$container_target" >/dev/null 2>&1 || cleanup_status=1
  fi
  if docker container inspect "$container_target" >/dev/null 2>&1; then
    printf 'async-fix smoke: container cleanup was incomplete: %s\n' "$container_target" >&2
    cleanup_status=1
  fi
  if [[ -d "$input_root" && "$(basename "$input_root")" == honeycomb-async-fix-inputs.* ]]; then
    rm -rf -- "$input_root" || cleanup_status=1
  else
    printf 'async-fix smoke: refusing to remove unexpected input path: %s\n' "$input_root" >&2
    cleanup_status=1
  fi

  if (( cleanup_status != 0 && status == 0 )); then
    status=68
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

set +e
container_output="$(/usr/bin/timeout --signal=TERM --kill-after=10s "${docker_timeout_seconds}s" \
docker run --rm \
  --name "$container_name" \
  --cidfile "$cid_file" \
  --network none \
  --pull=never \
  --read-only \
  --cap-drop=ALL \
  --pids-limit=256 \
  --stop-timeout=10 \
  --security-opt no-new-privileges \
  --tmpfs /tmp:rw,nosuid,nodev,exec,mode=1777,size=4g \
  -e TMPDIR=/tmp \
  -e "HONEYCOMB_SOURCE_REVISION=$honeycomb_revision" \
  -e "HIVE_SOURCE_REVISION=$hive_revision" \
  -v "$input_root/honeycomb:/inputs/honeycomb:ro" \
  -v "$input_root/hive:/inputs/hive:ro" \
  -v "$gem_cache:/inputs/gem-cache:ro" \
  --entrypoint /inputs/honeycomb/test/fixtures/async-fix/container_entry.sh \
  "$ruby_image")"
container_status=$?
set -e
if [[ -n "$container_output" ]]; then
  printf '%s\n' "$container_output"
fi
if (( container_status == 0 )); then
  if ! printf '%s\n' "$container_output" | ruby \
    "$input_root/honeycomb/test/fixtures/async-fix/validate_summary.rb" \
    "$honeycomb_revision" "$hive_revision"; then
    container_status=1
  fi
elif (( container_status == 124 )); then
  printf 'async-fix smoke: Docker acceptance timed out after %s seconds\n' \
    "$docker_timeout_seconds" >&2
fi

honeycomb_after="$(source_fingerprint "$honeycomb_root")"
readonly honeycomb_after
hive_after="$(source_fingerprint "$hive_root")"
readonly hive_after
if [[ "$honeycomb_before" != "$honeycomb_after" || "$hive_before" != "$hive_after" ]]; then
  printf 'async-fix smoke: a mounted source checkout changed\n' >&2
  exit 67
fi

exit "$container_status"
