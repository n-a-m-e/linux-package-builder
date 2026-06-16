#!/usr/bin/env bash
set -euo pipefail

command="${1:-}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

case "$command" in
  generate)
    rm -rf gpg-key
    mkdir -p gpg-key
    chmod 700 gpg-key
    export GNUPGHOME="$PWD/gpg-key"

    gpg --batch --generate-key "$script_dir/gpg-key.batch"
    fpr="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
    test -n "$fpr"
    echo "$fpr" > gpg-key/fingerprint.txt
    gpg --batch --armor --export-secret-keys "$fpr" > gpg-key/private.asc
    gpg --batch --armor --export "$fpr" > gpg-key/public.asc
    ;;
  setup)
    test -f gpg-key/private.asc
    test -f gpg-key/fingerprint.txt
    gpg --batch --import gpg-key/private.asc
    fpr="$(cat gpg-key/fingerprint.txt)"
    echo "fingerprint=$fpr" >> "$GITHUB_OUTPUT"
    ;;
  *)
    echo "Usage: $0 {generate|setup}" >&2
    exit 2
    ;;
esac
