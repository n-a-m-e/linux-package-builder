# linux-package-build-publisher

Reusable GitHub Actions workflow for publishing Flatpak, RPM, and DEB repositories to GitHub Pages.

All package types use one shared `targets` input. The meaning of each target depends on `package-type`.

## Shared inputs

```yaml
package-type: flatpak | rpm | deb
app-id: package-or-app-name
source-git: https://github.com/example/app.git
build-script: build.sh
targets: |
  target-one
  target-two
rebuild-trigger: |
  git app https://github.com/example/app.git main
```

`source-git`, `build-script`, or both are required.

## Target formats

### Flatpak targets

Flatpak targets use:

```text
<flatter-image>-<flatter-version>-<arch>
```

Examples:

```text
freedesktop-25.08-x86_64
gnome-49-aarch64
kde-6.10-x86_64
```

Flatpak currently supports exactly one target per workflow run. `targets` is required.

### RPM targets

RPM targets are mock config names and must end with an architecture suffix:

```text
<mock-config-family>-<arch>
```

Examples:

```text
fedora-44-x86_64
fedora-43-x86_64
fedora-42-x86_64
opensuse-tumbleweed-x86_64
alma+epel-9-x86_64
```

The RPM builder always uses Fedora tooling in `fedora:latest`. RPM targets select the mock buildroots.

### DEB targets

DEB targets are pbuilder target names and must end with an architecture suffix:

```text
<distribution-suite>-<arch>
```

Examples:

```text
ubuntu-noble-amd64
ubuntu-jammy-amd64
debian-bookworm-amd64
```

The DEB builder always uses Debian tooling in `debian:stable`. DEB targets select the pbuilder buildroots.

## Flatpak example

```yaml
jobs:
  publish:
    uses: n-a-m-e/linux-package-build-publisher/.github/workflows/publish.yml@main
    with:
      package-type: flatpak
      app-id: org.example.App
      source-git: https://github.com/example/app.git
      build-script: build.sh
      targets: |
        gnome-49-aarch64
      rebuild-trigger: |
        git app https://github.com/example/app.git main
```

## RPM example

```yaml
jobs:
  publish:
    uses: n-a-m-e/linux-package-build-publisher/.github/workflows/publish.yml@main
    with:
      package-type: rpm
      app-id: sonicde
      source-git: https://github.com/n-a-m-e/rpm-app-sonicde.git
      build-script: build.sh
      targets: |
        fedora-44-x86_64
        fedora-43-x86_64
        fedora-42-x86_64
      rebuild-trigger: |
        git sonic-specs https://pc-rytteren.dk/forge/anders/SonicDE-rpmspecs.git master
        git sonic-app https://github.com/n-a-m-e/rpm-app-sonicde.git main
```

RPM build scripts can queue packages with the publisher queue command:

```bash
package-build-queue add --clone-url https://example.invalid/specs.git --ref main --subdir package --spec package.spec
```


## DEB example

```yaml
jobs:
  publish:
    uses: n-a-m-e/linux-package-build-publisher/.github/workflows/publish.yml@main
    with:
      package-type: deb
      app-id: sonicde
      source-git: https://github.com/n-a-m-e/deb-app-sonicde.git
      build-script: build.sh
      targets: |
        ubuntu-noble-amd64
        ubuntu-jammy-amd64
        debian-bookworm-amd64
      rebuild-trigger: |
        git sonic-app https://github.com/n-a-m-e/deb-app-sonicde.git main
```

DEB build scripts can queue packages with:

```bash
package-build-queue add --package sonic-session --subdir packages/sonic-session
```


## Rebuild trigger format

`rebuild-trigger` is a newline-separated list. Blank lines and lines whose first non-space character is `#` are ignored. Inline comments are not stripped, so URLs containing `#` fragments are safe. Fields are split on shell whitespace, so values should not contain spaces.

Supported forms:

```text
url <name> <url>
git <name> <git-url> [ref]
file <name> <path>
```

Examples:

```text
url release https://example.invalid/latest-version.txt
git app https://github.com/example/app.git main
file manifest org.example.App.yaml
```

## Repository summary

RPM and DEB builds print a repository summary after the package build step:

```text
Targets published:
Packages detected:
Repository files generated:
```

## Package build contract

This repository intentionally uses a small, strict contract instead of broad fallback behaviour.

## Required inputs

All package types require:

- `package-type`: `flatpak`, `rpm`, or `deb`
- `app-id`: one or more package/application identifiers, one per line
- `rebuild-trigger`: one or more trigger lines
- `targets`: one or more explicit build targets
- `source-git`, `build-script`, or both

## Flatpak contract

Flatpak accepts exactly one target per workflow run, for example:

```yaml
targets: |
  freedesktop-25.08-x86_64
```

The source/build step must produce Flatpak manifests handled by the Flatpak path. Prebuilt Flatpak bundles are not supported.

## RPM contract

RPM builds require the app `build-script` to queue all packages with:

```bash
package-build-queue add \
  --clone-url <git-url> \
  --ref <ref-or-sha> \
  --subdir <package-subdir> \
  --spec <spec-file>
```

Optional package hint:

```bash
package-build-queue add \
  --package <binary-package-name> \
  --clone-url <git-url> \
  --ref <ref-or-sha> \
  --subdir <package-subdir> \
  --spec <spec-file>
```

`package-build-queue` is the only declaration command in this workflow; it writes package declarations to `/work/package-build-queue`.
Direct `.rpm`, `.spec`, COPR-compatible `copr-cli`, and other implicit fallback modes are not supported.

RPM targets are mock config names with an architecture suffix.
Supported architecture suffixes are `x86_64`, `aarch64`, `ppc64le`, and `s390x`.
Supported target families are currently validated as Fedora, openSUSE, AlmaLinux, AlmaLinux+EPEL, Rocky, EPEL, and CentOS Stream style mock configs.

Examples:

```yaml
targets: |
  fedora-44-x86_64
  opensuse-tumbleweed-x86_64
```

The queue shim records package names for README generation; README generation does not inspect built RPM files.

## DEB contract

DEB builds require the app `build-script` to queue all packages with:

```bash
package-build-queue add \
  --package <binary-package-name> \
  --subdir <source-subdir>
```

Optional source arguments are also supported:

```bash
package-build-queue add \
  --package <binary-package-name> \
  --clone-url <git-url> \
  --ref <ref-or-sha> \
  --subdir <source-subdir>
```

`package-build-queue` is the only declaration command in this workflow; it writes package declarations to `/work/package-build-queue`.
Direct `.deb`, `.dsc`, `deb-queue`, and implicit `debian/` fallback modes are not supported. Queued DEB sources must build source packages with `dpkg-buildpackage -S` and then `pbuilder` builds the binary packages.

DEB targets use a suite family plus architecture suffix.
Supported architecture suffixes are `amd64` and `arm64`.
Supported target families must start with `ubuntu-` or `debian-`.

Examples:

```yaml
targets: |
  ubuntu-noble-amd64
  debian-bookworm-amd64
```

The queue shim records package names for README generation; README generation does not inspect built DEB files.

## Metadata contract

RPM and DEB builds write one shared metadata layout:

```text
public/publisher-metadata/packages.txt
public/publisher-metadata/repos.tsv
public/publisher-metadata/targets.txt
```

README generation uses only these files for RPM/DEB package and repository information.

## Signing contract

All package types use the same generated repository signing identity and public key file:

```text
public/GPG-KEY-repo
```

## Strict effective build-time ordering for RPM and DEB

For `rpm` and `deb`, package declarations produced by the app build script are now treated as an unordered package universe. The publisher builds a strict effective build-time graph per target and only then executes builds in topological order.

The app repository should declare package inputs, not decide their build order:

```bash
# RPM
package-build-queue add \
  --package example \
  --clone-url file:///work/work/example \
  --ref HEAD \
  --subdir example \
  --spec example.spec

# DEB
package-build-queue add \
  --package example \
  --subdir packages/example
```


All declared package inputs are graph nodes. There is no special “local specs first” phase. Local specs, generated specs, fetched specs, and ordinary source packages are ordered only by the dependency graph.

The effective build-time rule is intentionally strict for both RPM and DEB:

```text
package P may build only after:
  every internal provider of P's direct build dependencies is built, and
  the runtime dependency closure of those build-dependency providers is built.
```

If the effective graph has a cycle, the publisher fails before building that target. It prints the unresolved package set, effective edges, direct build-dependency provider edges, and runtime provider edges to make the metadata problem visible instead of falling back to declaration order.

Graph artifacts are written under the build container for each target:

```text
/work/package-graph/rpm/<target>/
/work/package-graph/deb/<target>/
```

Each graph directory contains:

```text
nodes.tsv
providers.tsv
builddeps.tsv
runtimedeps.tsv
effective-builddeps.tsv
order.txt
node-queue.tsv
```
