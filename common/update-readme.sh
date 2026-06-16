#!/usr/bin/env bash
set -euo pipefail

publisher_root="${GITHUB_WORKSPACE:-$(pwd)}/publisher"
template_readme="$publisher_root/README.md"

if [[ ! -f "$template_readme" ]]; then
  echo "::error::Template README not found: $template_readme" >&2
  exit 1
fi

rm -rf repo-edit
git clone "https://x-access-token:${GH_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" repo-edit
cd repo-edit

app_list="$(printf '%s\n' "$APP" | sed '/^[[:space:]]*$/d' | sort -u | paste -sd' ' -)"

format_rpm_target_label() {
  local label="$1"

  if [[ "$label" =~ ^fedora-([0-9]+)$ ]]; then
    printf 'Fedora %s\n' "${BASH_REMATCH[1]}"
  elif [[ "$label" =~ ^opensuse-(.+)$ ]]; then
    printf 'openSUSE %s\n' "${BASH_REMATCH[1]}"
  elif [[ "$label" =~ ^centos-stream-(.+)$ ]]; then
    printf 'CentOS Stream %s\n' "${BASH_REMATCH[1]}"
  elif [[ "$label" =~ ^alma\+epel-(.+)$ ]]; then
    printf 'AlmaLinux + EPEL %s\n' "${BASH_REMATCH[1]}"
  elif [[ "$label" =~ ^rocky\+epel-(.+)$ ]]; then
    printf 'Rocky Linux + EPEL %s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "$label"
  fi
}

format_deb_target_label() {
  local label="$1"

  if [[ "$label" =~ ^ubuntu-(.+)$ ]]; then
    printf 'Ubuntu %s\n' "${BASH_REMATCH[1]^}"
  elif [[ "$label" =~ ^debian-(.+)$ ]]; then
    printf 'Debian %s\n' "${BASH_REMATCH[1]^}"
  else
    printf '%s\n' "$label"
  fi
}

rpm_target_uses_zypper() {
  local label="${1,,}"
  [[ "$label" == opensuse* || "$label" == suse* || "$label" == sles* || "$label" == sle-* ]]
}

package_list_from_metadata() {
  sed '/^[[:space:]]*$/d' ../publisher-metadata/packages.txt | sort -u | paste -sd' ' -
}

write_flatpak_instructions() {
  cat <<EOF
# Repository installation

> These instructions are generated from the latest published repository metadata.

## Flatpak repository

\`\`\`bash
sudo flatpak remote-add --if-not-exists "$REMOTE" "https://${OWNER}.github.io/${REPO}/index.flatpakrepo"
\`\`\`

\`\`\`bash
sudo flatpak install "$REMOTE" $app_list
\`\`\`
EOF
}

write_rpm_instructions() {
  [[ -s ../publisher-metadata/packages.txt && -s ../publisher-metadata/repos.tsv ]] || {
    echo "::error::Missing publisher metadata for RPM README" >&2
    exit 1
  }

  local package_list
  package_list="$(package_list_from_metadata)"

  cat <<EOF
# Repository installation

> These instructions are generated from the latest published repository metadata.

## RPM repository

Packages: \`$package_list\`

EOF

  sort -t $'\t' -k4,4 ../publisher-metadata/repos.tsv |
    while IFS=$'\t' read -r repo_id repo_file repo_path target_label; do
      [[ -n "$repo_file" ]] || continue

      local repo_url heading
      repo_url="https://${OWNER}.github.io/${REPO}/${repo_file}"
      heading="$(format_rpm_target_label "${target_label:-$repo_id}")"

      printf '### %s\n\n' "$heading"
      printf 'Repository file: `%s`\n\n' "$repo_url"

      if rpm_target_uses_zypper "${target_label:-$repo_id}"; then
        cat <<EOF
\`\`\`bash
sudo zypper addrepo --gpgcheck --refresh "$repo_url" "$repo_id"
sudo zypper install $package_list
\`\`\`

EOF
      else
        cat <<EOF
\`\`\`bash
sudo dnf config-manager addrepo --from-repofile="$repo_url"
sudo dnf install $package_list
\`\`\`

EOF
      fi
    done
}

write_deb_instructions() {
  [[ -s ../publisher-metadata/packages.txt && -s ../publisher-metadata/repos.tsv ]] || {
    echo "::error::Missing publisher metadata for DEB README" >&2
    exit 1
  }

  local package_list keyring
  package_list="$(package_list_from_metadata)"
  keyring="/usr/share/keyrings/${REPO}.gpg"

  cat <<EOF
# Repository installation

> These instructions are generated from the latest published repository metadata.

## DEB repository

Packages: \`$package_list\`

Signing key: \`https://${OWNER}.github.io/${REPO}/GPG-KEY-repo\`

EOF

  sort -t $'\t' -k4,4 ../publisher-metadata/repos.tsv |
    while IFS=$'\t' read -r repo_id repo_file repo_path target_label; do
      [[ -n "$repo_file" ]] || continue

      local key_url sources_url heading
      key_url="https://${OWNER}.github.io/${REPO}/GPG-KEY-repo"
      sources_url="https://${OWNER}.github.io/${REPO}/${repo_file}"
      heading="$(format_deb_target_label "${target_label:-$repo_id}")"

      printf '### %s\n\n' "$heading"
      printf 'Sources file: `%s`\n\n' "$sources_url"

      cat <<EOF
\`\`\`bash
sudo install -d -m 0755 /usr/share/keyrings
curl -fsSL "$key_url" | sudo gpg --dearmor -o "$keyring"
sudo curl -fsSL "$sources_url" -o "/etc/apt/sources.list.d/${repo_file}"
sudo apt update
sudo apt install $package_list
\`\`\`

EOF
    done
}

write_generated_instructions() {
  case "$PACKAGE_TYPE" in
    flatpak) write_flatpak_instructions ;;
    rpm) write_rpm_instructions ;;
    deb) write_deb_instructions ;;
    *)
      echo "::error::Unsupported package type for README generation: $PACKAGE_TYPE" >&2
      exit 1
      ;;
  esac
}

write_generated_instructions > ../generated-repository-instructions.md

{
  cat ../generated-repository-instructions.md
  printf '\n---\n\n'
  cat "$template_readme"
} > README.md

git config user.name github-actions[bot]
git config user.email 41898282+github-actions[bot]@users.noreply.github.com
git add README.md
git diff --cached --quiet || {
  git commit -m "Update README"
  git push
}
