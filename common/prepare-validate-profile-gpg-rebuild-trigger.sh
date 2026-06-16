#!/usr/bin/env bash
set -euo pipefail

[ "$(gh api repos/${GITHUB_REPOSITORY}/pages --jq .build_type 2>/dev/null || true)" = workflow ] || {
  echo "::error::Enable GitHub Pages with Source set to GitHub Actions."
  exit 1
}

case "$PACKAGE_TYPE" in
  flatpak|rpm|deb) echo "gpg-cache-key=package-gpg-key-v1" >> "$GITHUB_OUTPUT" ;;
  *) echo "::error::Unsupported package-type: $PACKAGE_TYPE"; exit 1 ;;
esac
if [[ -z "$SOURCE_GIT" && -z "$BUILD_SCRIPT" ]]; then
  echo "::error::$PACKAGE_TYPE requires source-git, build-script, or both."
  exit 1
fi


validate_rpm_target() {
  local target="$1" arch family
  target="$(printf '%s' "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$target" ]]; then
    echo "::error::Blank RPM target is not allowed."
    exit 1
  fi
  case "$target" in
    -*|*-|*" "*|*$'\t'*)
      echo "::error::Malformed RPM target: $target"
      exit 1
      ;;
  esac
  [[ "$target" == *-* ]] || { echo "::error::Malformed RPM target: $target. Expected <mock-config>-<arch>, for example fedora-44-x86_64."; exit 1; }
  arch="${target##*-}"
  family="${target%-${arch}}"
  case "$arch" in
    x86_64|aarch64|ppc64le|s390x) ;;
    *) echo "::error::Unsupported RPM architecture suffix in target: $target. Use x86_64, aarch64, ppc64le, or s390x."; exit 1 ;;
  esac
  if [[ "$family" =~ ^fedora-[0-9]+$ || \
        "$family" =~ ^opensuse-tumbleweed$ || \
        "$family" =~ ^opensuse-leap-[0-9]+(\.[0-9]+)?$ || \
        "$family" =~ ^alma-[0-9]+$ || \
        "$family" =~ ^alma\+epel-[0-9]+$ || \
        "$family" =~ ^rocky-[0-9]+$ || \
        "$family" =~ ^epel-[0-9]+$ || \
        "$family" =~ ^centos-stream-[0-9]+$ ]]; then
    return 0
  fi
  echo "::error::Unsupported RPM target family: $family. Expected a known mock family such as fedora-44 or opensuse-tumbleweed."
  exit 1
}

validate_deb_target() {
  local target="$1" arch family
  target="$(printf '%s' "$target" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  if [[ -z "$target" ]]; then
    echo "::error::Blank DEB target is not allowed."
    exit 1
  fi
  case "$target" in
    -*|*-|*" "*|*$'\t'*)
      echo "::error::Malformed DEB target: $target"
      exit 1
      ;;
  esac
  [[ "$target" == *-* ]] || { echo "::error::Malformed DEB target: $target. Expected <suite-family>-<arch>, for example ubuntu-noble-amd64."; exit 1; }
  arch="${target##*-}"
  family="${target%-${arch}}"
  case "$arch" in
    amd64|arm64) ;;
    *) echo "::error::Unsupported DEB architecture suffix in target: $target. Use amd64 or arm64."; exit 1 ;;
  esac
  if [[ "$family" =~ ^ubuntu-[a-z][a-z0-9-]*$ || "$family" =~ ^debian-[a-z][a-z0-9-]*$ ]]; then
    return 0
  fi
  echo "::error::Unsupported DEB target family: $family. Expected ubuntu-<suite> or debian-<suite>."
  exit 1
}

validate_package_targets() {
  local package_type="$1" target
  mapfile -t package_targets < <(printf '%s\n' "${TARGETS:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d')
  if [[ ${#package_targets[@]} -eq 0 ]]; then
    echo "::error::$package_type requires targets."
    exit 1
  fi
  for target in "${package_targets[@]}"; do
    case "$package_type" in
      rpm) validate_rpm_target "$target" ;;
      deb) validate_deb_target "$target" ;;
      *) echo "::error::Unsupported package type for target validation: $package_type"; exit 1 ;;
    esac
  done
}

flatpak_validate_profile() {
  local image="$1" version="$2" arch="$3"
  case "$image:$version:$arch" in
    freedesktop:24.08:x86_64|freedesktop:24.08:aarch64|freedesktop:25.08:x86_64|freedesktop:25.08:aarch64) ;;
    rust:24.08:x86_64|rust:24.08:aarch64|rust:25.08:x86_64|rust:25.08:aarch64) ;;
    rust-nightly:24.08:x86_64|rust-nightly:25.08:x86_64) ;;
    gnome:48:x86_64|gnome:48:aarch64|gnome:49:x86_64|gnome:49:aarch64|gnome:master:x86_64|gnome:master:aarch64) ;;
    gnome-rust:48:x86_64|gnome-rust:48:aarch64|gnome-rust:49:x86_64|gnome-rust:49:aarch64) ;;
    gnome-typescript:48:x86_64|gnome-typescript:48:aarch64|gnome-typescript:49:x86_64|gnome-typescript:49:aarch64) ;;
    gnome-vala:48:x86_64|gnome-vala:48:aarch64|gnome-vala:49:x86_64|gnome-vala:49:aarch64) ;;
    elementary:7.3:x86_64|elementary:7.3:aarch64|elementary:8.2:x86_64|elementary:8.2:aarch64|elementary:daily:x86_64|elementary:daily:aarch64) ;;
    qt:5.15-24.08:x86_64|qt:5.15-24.08:aarch64|qt:5.15-25.08:x86_64|qt:5.15-25.08:aarch64) ;;
    kde:6.9:x86_64|kde:6.9:aarch64|kde:6.10:x86_64|kde:6.10:aarch64) ;;
    workbench1:master:x86_64|workbench1:master:aarch64) ;;
    *) echo "::error::Unsupported Flatpak target: $image-$version-$arch"; exit 1 ;;
  esac
}

flatpak_parse_target() {
  local target="$1" arch rest pair image version
  arch="${target##*-}"
  rest="${target%-${arch}}"
  [[ -n "$rest" && "$rest" != "$target" ]] || { echo "::error::Invalid Flatpak target: $target"; exit 1; }

  while IFS=: read -r image version; do
    [[ -n "$image" ]] || continue
    if [[ "$rest" == "$image-$version" ]]; then
      printf '%s\t%s\t%s\n' "$image" "$version" "$arch"
      return 0
    fi
  done <<'TARGETS'
freedesktop:24.08
freedesktop:25.08
rust:24.08
rust:25.08
rust-nightly:24.08
rust-nightly:25.08
gnome:48
gnome:49
gnome:master
gnome-rust:48
gnome-rust:49
gnome-typescript:48
gnome-typescript:49
gnome-vala:48
gnome-vala:49
elementary:7.3
elementary:8.2
elementary:daily
qt:5.15-24.08
qt:5.15-25.08
kde:6.9
kde:6.10
workbench1:master
TARGETS

  echo "::error::Invalid Flatpak target: $target"
  exit 1
}

if [[ "$PACKAGE_TYPE" == flatpak ]]; then
  mapfile -t flatpak_targets < <(printf '%s\n' "${TARGETS:-}" | sed '/^[[:space:]]*$/d')
  if [[ ${#flatpak_targets[@]} -eq 0 ]]; then
    echo "::error::Flatpak requires targets."
    exit 1
  fi
  if [[ ${#flatpak_targets[@]} -ne 1 ]]; then
    echo "::error::Flatpak currently supports exactly one target per workflow run."
    exit 1
  fi
  IFS=$'\t' read -r image version arch < <(flatpak_parse_target "${flatpak_targets[0]}")
  flatpak_validate_profile "$image" "$version" "$arch"
  container="ghcr.io/andyholmes/flatter/${image}:${version}"
  printf 'build-container-json={"image":"%s","options":"--privileged"}\n' "$container" >> "$GITHUB_OUTPUT"
  printf 'flatpak-arch=%s\n' "$arch" >> "$GITHUB_OUTPUT"
else
  if [[ "$PACKAGE_TYPE" == rpm ]]; then
    validate_package_targets rpm
  elif [[ "$PACKAGE_TYPE" == deb ]]; then
    validate_package_targets deb
  fi
  echo 'build-container-json=null' >> "$GITHUB_OUTPUT"
  echo 'flatpak-arch=x86_64' >> "$GITHUB_OUTPUT"
fi

if [[ "$GPG_CACHE_HIT" != true ]]; then
  bash publisher/common/gpg.sh generate
else
  test -f gpg-key/private.asc
  test -f gpg-key/public.asc
  test -f gpg-key/fingerprint.txt
fi

: > version.txt
while IFS= read -r line || [ -n "$line" ]; do
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$line" ] || continue
  case "$line" in \#*) continue ;; esac
  set -- $line
  kind="${1:-}"; name="${2:-}"; value="${3:-}"; ref="${4:-}"
  case "$kind" in
    url)
      result="$(curl -fsSL --retry 3 --retry-delay 10 --retry-all-errors "$value")"
      printf '%s	url	%s	%s\n' "$name" "$value" "$result" >> version.txt
      ;;
    git)
      ref="${ref:-HEAD}"
      sha="$(git ls-remote "$value" "$ref" | awk '{print $1}' | head -n1)"
      [ -n "$sha" ] || { echo "::error::Unable to resolve git trigger: $value $ref"; exit 1; }
      printf 'git %s %s %s %s\n' "$name" "$value" "$ref" "$sha" >> version.txt
      ;;
    file)
      [ -f "$value" ] || { echo "::error::Missing trigger file: $value"; exit 1; }
      hash="$(sha256sum "$value" | cut -d' ' -f1)"
      printf 'file %s %s %s\n' "$name" "$value" "$hash" >> version.txt
      ;;
    *)
      echo "::error::Unknown rebuild-trigger type: $kind"
      exit 1
      ;;
  esac
done <<< "$REBUILD_TRIGGER"

version_hash="$(sha256sum version.txt | cut -d' ' -f1)"
app_hash="$(printf '%s' "$APP" | sha256sum | cut -d' ' -f1)"
key="upstream-state-${app_hash}-${version_hash}"
echo "version-key=$key" >> "$GITHUB_OUTPUT"

if [[ "$GITHUB_EVENT_NAME" == workflow_dispatch ]]; then
  echo "changed=true" >> "$GITHUB_OUTPUT"
elif gh cache list --key "$key" --json key --jq '.[].key' | grep -Fxq "$key"; then
  echo "changed=false" >> "$GITHUB_OUTPUT"
else
  echo "changed=true" >> "$GITHUB_OUTPUT"
fi
