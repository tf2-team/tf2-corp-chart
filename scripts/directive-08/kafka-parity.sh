#!/usr/bin/env sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <bootstrap-servers> <label> [command-config]" >&2
  exit 2
fi

brokers="$1"
label="$2"
config="${3:-}"
auth_args=""
[ -z "$config" ] || auth_args="--command-config $config"

# shellcheck disable=SC2086
kafka-topics.sh --bootstrap-server "$brokers" $auth_args --describe \
  | LC_ALL=C sort > "kafka-${label}-topics.txt"

for topic in orders orders-approved orders-cancelled orders-shipped orders-persisted; do
  # shellcheck disable=SC2086
  kafka-get-offsets.sh --bootstrap-server "$brokers" $auth_args --topic "$topic" \
    | LC_ALL=C sort >> "kafka-${label}-offsets.txt"
done

echo "Captured kafka-${label}-topics.txt and kafka-${label}-offsets.txt"

