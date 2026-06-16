#!/usr/bin/env bash
# RPM-specific hooks for the shared container build driver.

package_container_image() {
  printf 'fedora:latest\n'
}

package_install_tools() {
  dnf -y install \
    createrepo_c \
    curl \
    diffutils \
    findutils \
    git \
    gnupg2 \
    mock \
    mock-core-configs \
    patch \
    rpm-build \
    rpm-sign \
    rpmdevtools \
    sed \
    tar \
    util-linux \
    which \
    python3
}

package_configure_signing() {
  cat > /root/.rpmmacros <<EOF_MACROS
%_signature gpg
%_gpg_name $FPR
%_gpg_path $GNUPGHOME
%_gpgbin /usr/bin/gpg
%_gpg_digest_algo sha256
%__gpg /usr/bin/gpg
EOF_MACROS
}

package_init_dirs() {
  mkdir -p /work/public /work/package-build-queue /work/rpm-results /package-cache/rpm
}

package_export_public_key() {
  gpg --batch --armor --export "$FPR" > /work/public/GPG-KEY-repo
  rpm --import /work/public/GPG-KEY-repo
}

package_install_queue_shim() {
  install -m 0755 /work/publisher/common/package-build-queue.sh /usr/local/bin/package-build-queue
}

package_queue_contract_message() {
  printf '%s\n' 'RPM build contract requires build-script to declare all package inputs with package-build-queue add. Build order is resolved by the strict effective graph.'
}

package_index_title() {
  printf 'RPM repository\n'
}

filter_known_mock_log_noise() {
  grep -v -F 'error: incorrect format: unknown tag: "pkgid"' || true
}

dump_mock_logs() {
  local result_dir="$1" log
  for log in root.log build.log state.log installed_pkgs.log; do
    if [[ -f "$result_dir/$log" ]]; then
      echo "===== $log ====="
      filter_known_mock_log_noise < "$result_dir/$log"
      echo "===== end $log ====="
    fi
  done
}

mock_rebuild() {
  local mock_config="$1" uniqueext="$2" result_dir="$3" local_repo="$4" srpm="$5" url="${6:-}"
  mock -r "$mock_config" --init
  if ! mock -r "$mock_config" \
    --uniqueext "$uniqueext" \
    ${url:+--define "url $url"} \
    --enable-network \
    --addrepo "file://$local_repo" \
    --resultdir "$result_dir" \
    --rebuild "$srpm"; then
    dump_mock_logs "$result_dir"
    exit 1
  fi
}

fetch_sources() {
  local pkg_dir="$1" spec_name="$2" spec_path="$3" url="$4" src base
  if ! (cd "$pkg_dir" && spectool ${url:+--define "url $url"} -g -C "$pkg_dir" "$spec_name"); then
    echo "::error::spectool failed while fetching sources for $spec_path"
    exit 1
  fi
  rpmspec ${url:+--define "url $url"} -P "$spec_path" | awk '/^Source[0-9]*:/ {print $2}' | while read -r src; do
    [[ -n "$src" ]] || continue
    base="$(basename "$src")"
    if [[ ! -f "$pkg_dir/$base" && "$src" =~ ^https?:// ]]; then
      curl -fL --retry 3 -o "$pkg_dir/$base" "$src"
    fi
  done
}

patch_file_hashes() {
  local patch_root="$1" spec_name="$2" target_family_name="$3" target_name="$4"
  local base_name="${spec_name%.spec}"
  hash_layered_files "$patch_root" "$target_family_name" "$target_name" \
    "${spec_name}.patch" \
    "${base_name}.source.patch"
}

package_compat_root() {
  printf '%s\n' "/work/work/${primary_app}"
}

rpm_macro_files() {
  local compat_root="$1" target_family_name="$2" target_name="$3"
  layered_glob_files "$compat_root" "$target_family_name" "$target_name" 'macros/*.macros'
}

rpm_macro_file_hashes() {
  local compat_root="$1" target_family_name="$2" target_name="$3" file
  while IFS= read -r file; do
    [[ ! -f "$file" ]] || sha256sum "$file"
  done < <(rpm_macro_files "$compat_root" "$target_family_name" "$target_name")
}

rpm_replacement_files() {
  local compat_root="$1" target_family_name="$2" target_name="$3"
  layered_glob_files "$compat_root" "$target_family_name" "$target_name" 'replacements/*.sed'
}

rpm_replacement_file_hashes() {
  local compat_root="$1" target_family_name="$2" target_name="$3" file
  while IFS= read -r file; do
    [[ ! -f "$file" ]] || sha256sum "$file"
  done < <(rpm_replacement_files "$compat_root" "$target_family_name" "$target_name")
}

apply_rpm_replacements_to_spec() {
  local spec_path="$1" compat_root="$2" target_family_name="$3" target_name="$4"
  local sed_files=() file tmp
  mapfile -t sed_files < <(rpm_replacement_files "$compat_root" "$target_family_name" "$target_name")
  [[ ${#sed_files[@]} -gt 0 ]] || return 0

  tmp="${spec_path}.with-replacements"
  cp "$spec_path" "$tmp"

  for file in "${sed_files[@]}"; do
    [[ -f "$file" ]] || continue
    echo "Applying RPM replacements: $file"
    sed -f "$file" -i "$tmp"
  done

  mv "$tmp" "$spec_path"
}

prepend_rpm_macros_to_spec() {
  local spec_path="$1" compat_root="$2" target_family_name="$3" target_name="$4"
  local macro_files=() file tmp
  mapfile -t macro_files < <(rpm_macro_files "$compat_root" "$target_family_name" "$target_name")
  [[ ${#macro_files[@]} -gt 0 ]] || return 0

  tmp="${spec_path}.with-macros"
  : > "$tmp"
  for file in "${macro_files[@]}"; do
    [[ -f "$file" ]] || continue
    echo "Loading RPM macros: $file"
    printf '# begin rpm macros: %s\n' "$file" >> "$tmp"
    cat "$file" >> "$tmp"
    printf '\n# end rpm macros: %s\n\n' "$file" >> "$tmp"
  done
  cat "$spec_path" >> "$tmp"
  mv "$tmp" "$spec_path"
}

apply_patches_and_build_srpm() {
  local build_id="$1" clone_url="$2" commit="$3" subdir="$4" spec_name="$5" workdir="$6" srpm_dir="$7" patch_root="$8" target_family_name="$9" target_name="${10}"
  rm -rf "$workdir" "$srpm_dir"
  mkdir -p "$workdir" "$srpm_dir"
  git clone --recursive "$clone_url" "$workdir/src"
  (cd "$workdir/src" && git checkout "$commit")
  local pkg_dir="$workdir/src/$subdir"
  [[ -d "$pkg_dir" ]] || { echo "::error::Missing subdir: $subdir"; exit 1; }
  local spec_path="$pkg_dir/$spec_name"
  [[ -f "$spec_path" ]] || { echo "::error::Missing spec: $spec_path"; exit 1; }
  local base_name="${spec_name%.spec}"

  apply_git_layered_patches "$workdir/src" "$patch_root" "$target_family_name" "$target_name" "${spec_name}.patch"
  copy_layered_files "$pkg_dir" "$patch_root" "$target_family_name" "$target_name" "${base_name}.source.patch"
  apply_rpm_replacements_to_spec "$spec_path" "$(package_compat_root)" "$target_family_name" "$target_name"
  prepend_rpm_macros_to_spec "$spec_path" "$(package_compat_root)" "$target_family_name" "$target_name"

  local url
  url="$(awk 'tolower($1)=="url:" {print $2; exit}' "$spec_path" || true)"
  fetch_sources "$pkg_dir" "$spec_name" "$spec_path" "$url"
  rpmbuild -bs "$spec_path" \
    --define "_sourcedir $pkg_dir" \
    --define "_srcrpmdir $srpm_dir" \
    --define "_specdir $pkg_dir" \
    ${url:+--define "url $url"}
}

build_queue_item() {
  local queue_file="$1" mock_config="$2" target_family_name="$3" target_name="$4" target_arch_name="$5" repo_dir="$6" src_repo_dir="$7" local_repo="$8"
  # shellcheck source=/dev/null
  source "$queue_file"
  local build_id="${SUBDIR//\//_}"
  local cache_dir="/package-cache/rpm/${primary_app}/${target_name}/${build_id}"
  local workdir="/work/rpm-build/${target_name}/${build_id}"
  local srpm_dir="/work/rpm-srpm/${target_name}/${build_id}"
  local result_dir="/work/rpm-result/${target_name}/${build_id}"
  mkdir -p "$cache_dir" "$result_dir" "$repo_dir" "$src_repo_dir" "$local_repo"
  createrepo_c "$local_repo" || true

  local patch_root compat_root spec_hash patch_hash macro_hash replacement_hash ref_fingerprint tmpclone fingerprint srpm url
  patch_root="/work/work/${primary_app}/patches"
  compat_root="$(package_compat_root)"
  spec_hash=""
  patch_hash=""
  macro_hash=""
  replacement_hash=""
  tmpclone="/work/fingerprint-${target_name}-${build_id}"
  rm -rf "$tmpclone"
  git clone --depth 1 "$CLONE_URL" "$tmpclone" >/dev/null 2>&1 || true
  if [[ -f "$tmpclone/$SUBDIR/$SPEC" ]]; then
    spec_hash="$(sha256sum "$tmpclone/$SUBDIR/$SPEC" | cut -d' ' -f1)"
  fi
  rm -rf "$tmpclone"
  patch_hash="$(patch_file_hashes "$patch_root" "$SPEC" "$target_family_name" "$target_name" | sha256sum | cut -d' ' -f1)"
  macro_hash="$(rpm_macro_file_hashes "$compat_root" "$target_family_name" "$target_name" | sha256sum | cut -d' ' -f1)"
  replacement_hash="$(rpm_replacement_file_hashes "$compat_root" "$target_family_name" "$target_name" | sha256sum | cut -d' ' -f1)"
  ref_fingerprint="$REF"
  case "$CLONE_URL" in
    "file:///work/work/${primary_app}/sonicde-specs")
      ref_fingerprint="local-sonicde-specs-content"
      ;;
  esac
  fingerprint="$(printf '%s\n' "$CLONE_URL" "$ref_fingerprint" "$SUBDIR" "$SPEC" "$mock_config" "$target_arch_name" "$spec_hash" "$patch_hash" "$macro_hash" "$replacement_hash" | sha256sum | cut -d' ' -f1)"

  if [[ -f "$cache_dir/.fingerprint" && "$(cat "$cache_dir/.fingerprint")" == "$fingerprint" ]] && compgen -G "$cache_dir/*.rpm" >/dev/null; then
    echo "Using cached RPMs for $target_name/$build_id"
    cp -f "$cache_dir"/*.rpm "$repo_dir"/ || true
    cp -f "$cache_dir"/*.src.rpm "$src_repo_dir"/ || true
    cp -f "$cache_dir"/*.rpm "$local_repo"/ || true
    createrepo_c --update "$local_repo" || true
    return 0
  fi

  apply_patches_and_build_srpm "$build_id" "$CLONE_URL" "${REF:-master}" "$SUBDIR" "$SPEC" "$workdir" "$srpm_dir" "$patch_root" "$target_family_name" "$target_name"
  srpm="$(find "$srpm_dir" -maxdepth 1 -type f -name '*.src.rpm' -print -quit)"
  [[ -n "$srpm" ]] || { echo "::error::No SRPM created for $target_name/$build_id"; exit 1; }
  url="$(awk 'tolower($1)=="url:" {print $2; exit}' "$workdir/src/$SUBDIR/$SPEC" || true)"
  mock_rebuild "$mock_config" "$target_name-$build_id" "$result_dir" "$local_repo" "$srpm" "$url"

  rm -f "$cache_dir"/*.rpm "$cache_dir"/*.src.rpm
  find "$result_dir" -type f -name '*.rpm' -exec cp -f {} "$cache_dir" \;
  echo "$fingerprint" > "$cache_dir/.fingerprint"
  find "$result_dir" -type f -name '*.rpm' ! -name '*.src.rpm' -exec cp -f {} "$repo_dir" \;
  find "$result_dir" -type f -name '*.src.rpm' -exec cp -f {} "$src_repo_dir" \;
  find "$result_dir" -type f -name '*.rpm' ! -name '*.src.rpm' -exec cp -f {} "$local_repo" \;
  createrepo_c --update "$local_repo" || true
}

sign_and_index_repo() {
  local repo_dir="$1"
  shopt -s nullglob
  local rpms=("$repo_dir"/*.rpm)
  if [[ ${#rpms[@]} -gt 0 ]]; then
    for r in "${rpms[@]}"; do rpmsign --addsign "$r"; rpm --checksig "$r"; done
    createrepo_c "$repo_dir"
    gpg --batch --yes --armor --detach-sign "$repo_dir/repodata/repomd.xml"
  fi
  local src_dir="$repo_dir/source"
  local srpms=("$src_dir"/*.src.rpm)
  if [[ ${#srpms[@]} -gt 0 ]]; then
    for r in "${srpms[@]}"; do rpmsign --addsign "$r"; rpm --checksig "$r"; done
    createrepo_c "$src_dir"
    gpg --batch --yes --armor --detach-sign "$src_dir/repodata/repomd.xml"
  fi
}

write_repo_file() {
  local repo_id="$1" repo_path="$2" repo_file="$3" target_label_name="$4"
  {
    printf '[%s]\n' "$repo_id"
    printf 'name=%s RPM repository\n' "$repo_id"
    printf 'baseurl=https://%s.github.io/%s/%s\n' "$REPO_OWNER" "$REPO_NAME" "$repo_path"
    printf 'enabled=1\n'
    printf 'gpgcheck=1\n'
    printf 'repo_gpgcheck=1\n'
    printf 'gpgkey=https://%s.github.io/%s/GPG-KEY-repo\n' "$REPO_OWNER" "$REPO_NAME"
    printf 'skip_if_unavailable=True\n'
  } > "/work/public/${repo_file}"
  printf '%s\t%s\t%s\t%s\n' "$repo_id" "$repo_file" "$repo_path" "$target_label_name" >> /work/public/publisher-metadata/repos.tsv
}


rpm_graph_node_id() {
  local queue_file="$1"
  (
    # shellcheck source=/dev/null
    source "$queue_file"
    local hint="${PACKAGE:-${SPEC%.spec}}"
    queue_safe_id "${hint}-${SUBDIR}"
  )
}

rpm_dep_name() {
  sed -E '
    s/#.*//;
    s/[[:space:]]+(>=|<=|=|>|<).*$//;
    s/^[[:space:]("'"'"']+//;
    s/[[:space:],)"'"'"']+$//;
  ' <<< "$1" | awk '{print $1}'
}

rpm_graph_query_spec_raw() {
  local spec_path="$1" mode="$2"
  case "$mode" in
    names)         rpmspec -q --qf '%{NAME}\n' "$spec_path" ;;
    provides)      rpmspec -q --provides "$spec_path" ;;
    requires)      rpmspec -q --requires "$spec_path" ;;
    buildrequires) rpmspec -q --buildrequires "$spec_path" ;;
    *) echo "::error::unknown RPM graph query mode: $mode"; exit 1 ;;
  esac
}

rpm_graph_query_spec() {
  local spec_path="$1" mode="$2"
  rpm_graph_query_spec_raw "$spec_path" "$mode" \
    | while read -r line; do rpm_dep_name "$line"; done \
    | awk 'NF' \
    | sort -u
}

rpm_graph_log_spec_package_metadata() {
  local graph_root="$1" node_id="$2" spec_path="$3" mode raw_file norm_file
  local meta_dir="$graph_root/spec-metadata/$node_id"
  mkdir -p "$meta_dir"

  printf '%s\t%s\n' "$node_id" "$spec_path" >> "$graph_root/specpaths.tsv"

  for mode in names provides requires buildrequires; do
    raw_file="$meta_dir/${mode}.raw.txt"
    norm_file="$meta_dir/${mode}.txt"
    rpm_graph_query_spec_raw "$spec_path" "$mode" | sort -u > "$raw_file"
    rpm_graph_query_spec "$spec_path" "$mode" > "$norm_file"
  done

  while read -r name; do
    [[ -n "$name" ]] && printf '%s\t%s\n' "$node_id" "$name" >> "$graph_root/package-names.tsv"
  done < "$meta_dir/names.txt"

  while read -r provide; do
    [[ -n "$provide" ]] && printf '%s\t%s\n' "$node_id" "$provide" >> "$graph_root/package-provides.tsv"
  done < "$meta_dir/provides.txt"

  {
    echo "::group::RPM spec metadata: $node_id"
    echo "Spec: $spec_path"
    echo "Package names:"
    sed 's/^/  /' "$meta_dir/names.txt"
    echo "Selected devel/package aliases:"
    grep -E '(^|[-_])(devel|dev)$|cmake\(|pkgconfig\(|^kf6-' "$meta_dir/provides.txt" | sed 's/^/  /' || true
    echo "::endgroup::"
  } >&2
}
rpm_graph_prepare_source() {
  local queue_file="$1" graph_root="$2" family="$3" target="$4" node_id="$5"
  # shellcheck source=/dev/null
  source "$queue_file"
  local checkout="$graph_root/src/$node_id"
  local prepared="$graph_root/prepared/$node_id"
  rm -rf "$checkout" "$prepared"
  mkdir -p "$(dirname "$checkout")" "$(dirname "$prepared")"
  git clone --recursive "$CLONE_URL" "$checkout" >/dev/null
  (cd "$checkout" && git checkout "${REF:-master}" >/dev/null)
  local pkg_dir="$checkout/$SUBDIR"
  [[ -d "$pkg_dir" ]] || { echo "::error::Missing RPM graph subdir: $SUBDIR"; exit 1; }
  local spec_path="$pkg_dir/$SPEC"
  [[ -f "$spec_path" ]] || { echo "::error::Missing RPM graph spec: $spec_path"; exit 1; }

  # Apply the same package-level transformations used for the actual SRPM build,
  # because graph metadata must describe the effective package, not the pristine spec.
  local patch_root="/work/work/${primary_app}/patches"
  local base_name="${SPEC%.spec}"
  apply_git_layered_patches "$checkout" "$patch_root" "$family" "$target" "${SPEC}.patch"
  copy_layered_files "$pkg_dir" "$patch_root" "$family" "$target" "${base_name}.source.patch"
  apply_rpm_replacements_to_spec "$spec_path" "$(package_compat_root)" "$family" "$target"
  prepend_rpm_macros_to_spec "$spec_path" "$(package_compat_root)" "$family" "$target"

  mkdir -p "$prepared"
  cp "$spec_path" "$prepared/$SPEC"
  printf '%s\n' "$prepared/$SPEC"
}

rpm_graph_add_provider() {
  local providers_file="$1" dep_name="$2" node_id="$3" old
  [[ -n "$dep_name" ]] || return 0
  old="$(awk -F '\t' -v p="$dep_name" '$1==p{print $2; exit}' "$providers_file" 2>/dev/null || true)"
  if [[ -n "$old" && "$old" != "$node_id" ]]; then
    echo "::error::ambiguous internal RPM provider '$dep_name': $old and $node_id"
    exit 1
  fi
  [[ -n "$old" ]] || printf '%s\t%s\n' "$dep_name" "$node_id" >> "$providers_file"
}

rpm_graph_provider() {
  local providers_file="$1" dep_name="$2"
  awk -F '\t' -v p="$dep_name" '$1==p{print $2; exit}' "$providers_file"
}

rpm_order_queue_files_for_target() {
  local target="$1" family="$2"
  local graph_root="/work/package-graph/rpm/$target"
  local queue_file node_id spec_path dep prov
  rm -rf "$graph_root"
  mkdir -p "$graph_root"
  : > "$graph_root/nodes.tsv"
  : > "$graph_root/providers.tsv"
  : > "$graph_root/builddeps.tsv"
  : > "$graph_root/runtimedeps.tsv"
  : > "$graph_root/node-queue.tsv"
  : > "$graph_root/specpaths.tsv"
  : > "$graph_root/package-names.tsv"
  : > "$graph_root/package-provides.tsv"

  mapfile -t queue_items < <(queue_list_files /work/package-build-queue)
  [[ ${#queue_items[@]} -gt 0 ]] || { echo "::error::No RPM package declarations were queued"; exit 1; }

  for queue_file in "${queue_items[@]}"; do
    node_id="$(rpm_graph_node_id "$queue_file")"
    printf '%s\n' "$node_id" >> "$graph_root/nodes.tsv"
    printf '%s\t%s\n' "$node_id" "$queue_file" >> "$graph_root/node-queue.tsv"
    spec_path="$(rpm_graph_prepare_source "$queue_file" "$graph_root" "$family" "$target" "$node_id" | tee /dev/stderr | tail -n1)"
    printf '%s\n' "$spec_path" > "$graph_root/$node_id.specpath"
    rpm_graph_log_spec_package_metadata "$graph_root" "$node_id" "$spec_path"
    while read -r dep; do rpm_graph_add_provider "$graph_root/providers.tsv" "$dep" "$node_id"; done < <(rpm_graph_query_spec "$spec_path" names)
    while read -r dep; do rpm_graph_add_provider "$graph_root/providers.tsv" "$dep" "$node_id"; done < <(rpm_graph_query_spec "$spec_path" provides)
  done

  sort -u "$graph_root/providers.tsv" -o "$graph_root/providers.tsv"
  sort -u "$graph_root/package-names.tsv" -o "$graph_root/package-names.tsv"
  sort -u "$graph_root/package-provides.tsv" -o "$graph_root/package-provides.tsv"

  {
    echo "::group::RPM internal package names for $target"
    column -t -s $'\t' "$graph_root/package-names.tsv" || cat "$graph_root/package-names.tsv"
    echo "::endgroup::"
  } >&2

  for node_id in $(cut -f1 "$graph_root/nodes.tsv"); do
    spec_path="$(cat "$graph_root/$node_id.specpath")"
    while read -r dep; do
      prov="$(rpm_graph_provider "$graph_root/providers.tsv" "$dep")"
      [[ -z "$prov" || "$prov" == "$node_id" ]] || printf '%s\t%s\t%s\n' "$prov" "$node_id" "$dep" >> "$graph_root/builddeps.tsv"
    done < <(rpm_graph_query_spec "$spec_path" buildrequires)
    while read -r dep; do
      prov="$(rpm_graph_provider "$graph_root/providers.tsv" "$dep")"
      [[ -z "$prov" || "$prov" == "$node_id" ]] || printf '%s\t%s\t%s\n' "$prov" "$node_id" "$dep" >> "$graph_root/runtimedeps.tsv"
    done < <(rpm_graph_query_spec "$spec_path" requires)
  done

  sort -u "$graph_root/builddeps.tsv" -o "$graph_root/builddeps.tsv"
  sort -u "$graph_root/runtimedeps.tsv" -o "$graph_root/runtimedeps.tsv"

  python3 /work/publisher/common/effective-build-graph.py \
    --nodes "$graph_root/nodes.tsv" \
    --builddeps "$graph_root/builddeps.tsv" \
    --runtimedeps "$graph_root/runtimedeps.tsv" \
    --effective-edges-out "$graph_root/effective-builddeps.tsv" \
    > "$graph_root/order.txt"

  while read -r node_id; do
    awk -F '\t' -v n="$node_id" '$1==n{print $2; exit}' "$graph_root/node-queue.tsv"
  done < "$graph_root/order.txt"
}

build_queue_for_target() {
  local mock_config="$1" repo_id repo_path repo_file family arch label repo_dir src_repo_dir local_repo queue_item
  IFS=$'\t' read -r repo_id repo_path repo_file family arch label < <(repo_info_for_target rpm "$primary_app" "$mock_config" "$target_layout")
  repo_dir="/work/public/${repo_path}"
  src_repo_dir="${repo_dir}/source"
  local_repo="/work/localrepo-${mock_config}"
  mkdir -p "$repo_dir" "$src_repo_dir" "$local_repo"
  createrepo_c "$local_repo" || true
  mapfile -t queue_items < <(rpm_order_queue_files_for_target "$mock_config" "$family")
  for queue_item in "${queue_items[@]}"; do
    build_queue_item "$queue_item" "$mock_config" "$family" "$mock_config" "$arch" "$repo_dir" "$src_repo_dir" "$local_repo"
  done
  sign_and_index_repo "$repo_dir"
  write_repo_file "$repo_id" "$repo_path" "$repo_file" "$label"
  printf '%s\n' "$mock_config" >> /work/public/publisher-metadata/targets.txt
}

package_build_all_targets() {
  mapfile -t RPM_TARGET_LIST < <(printf '%s
' "${TARGETS:-}" | sed '/^[[:space:]]*$/d')

  target_layout=true
  local target
  for target in "${RPM_TARGET_LIST[@]}"; do
    echo "Building RPM target: $target"
    build_queue_for_target "$target"
  done
}

package_finalize_metadata() {
  metadata_sort_unique \
    /work/public/publisher-metadata/packages.txt \
    /work/public/publisher-metadata/repos.tsv \
    /work/public/publisher-metadata/targets.txt
}
