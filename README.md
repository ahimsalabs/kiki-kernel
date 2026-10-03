# kiki-kernel

The guest kernel [kiki](https://github.com/ahimsalabs/kiki) boots its
Cloud Hypervisor VMs with: Kata Containers' pinned kernel and config, plus a
small kiki fragment, for amd64 (an uncompressed PVH `vmlinux` ELF) and arm64
(an `Image`). It is built with Kata's own `build-kernel.sh`, so the result
is Kata's kernel with a few options added, and nothing else.

Published as the OCI artifact `ghcr.io/ahimsalabs/kiki-kernel:<release>` and
as the GitHub release `v<release>` with the same files, where `<release>` is
`<kernel version>-<kata_config_version>-kiki.<revision>`, such as
`6.18.35-202-kiki.1`. kiki pins each architecture's blob by SHA-256 and size
(`internal/artifacts` there), and `kiki setup artifacts` fetches the one for
the host's architecture.

## What kiki adds

`fragments/common.conf` (every architecture) and `fragments/x86_64.conf`:

| Option | Why |
|---|---|
| `VIRTUALIZATION`, `KVM`; `KVM_AMD`, `KVM_INTEL` on amd64 | VMs inside a VM (kiki#76). Inert unless Cloud Hypervisor exposes virtualization (`nested=on`): without SVM or VMX the vendor module does not initialize and no `/dev/kvm` appears, so one kernel serves every VM |
| `BTRFS_FS`, `BTRFS_FS_POSIX_ACL` | an inner kiki's data dir on an extra disk |
| `IKCONFIG`, `IKCONFIG_PROC` | `/proc/config.gz`: the running kernel's config, for the guest and a host-side check |
| `DEBUG_INFO_BTF` | BTF type information for eBPF (kiki#64). DWARF is needed only to generate it: the amd64 `vmlinux` is published with its DWARF stripped |

Everything else in the config is Kata's: without kiki's fragments the build
reproduces Kata's published `config-<version>-<config version>` to the byte,
and with them the only differences are these options and what Kconfig
selects for them (KVM's helpers, btrfs's checksums and compressors, and, on
amd64, `X86_FRED`, which `KVM_INTEL` selects and which stays off on CPUs
without FRED). `build.sh` fails the build if Kconfig drops or changes any
option kiki's fragments ask for. An inner Cloud Hypervisor needs nothing more: its vsock
is its own (hybrid, not vhost-vsock), and Kata's config has TUN.

## Release contents

Layers of `ghcr.io/ahimsalabs/kiki-kernel:<release>`, and assets of the
GitHub release `v<release>`:

| File | Contents |
|---|---|
| `kiki-kernel-<release>-amd64.tar.zst`, `-arm64.tar.zst` | a zstd tar (media type `application/vnd.ahimsalabs.kiki.kernel.layer.v1.tar+zstd`) holding at its root `vmlinux-<release>` (amd64: the PVH ELF; arm64: the `Image`), `config-<release>` (the exact `.config` it was built from) and `buildinfo-<release>` (inputs and toolchain versions) |
| `config-<release>-amd64`, `-arm64` | the same configs, uncompressed |
| `kiki-kernel-<release>-source.tar` | the complete corresponding source; see [Licensing](#licensing) |
| `SHA256SUMS` | GitHub release only |

The Build workflow's summary for a release lists every file's size and
SHA-256, and the members kiki pins.

Measured for `6.18.35-202-kiki.1` (the Kata 4.2.0 kernel is the comparison):

| | amd64 `vmlinux` | arm64 `Image` |
|---|---|---|
| Kata 6.18.35-202 | 40,855,000 B | 18,815,488 B |
| kiki 6.18.35-202-kiki.1 | 49,441,920 B | 26,401,280 B |
| its zstd tar | 11,393,586 B | 9,461,146 B |

On amd64, 5.3 MB of the growth is `.BTF` and 2.3 MB is KVM's and btrfs's
code and data. A VM booting to an `/init` that powers off at once took
133 ms with kiki's kernel against 119 ms with Kata's (Cloud Hypervisor v53,
2 vCPU, 1 GiB, AMD Ryzen 9 7950X host, median of 50 interleaved runs each,
from starting Cloud Hypervisor to its exit). The source tar is 156 MB.

## Building

The build runs in the builder image (`Dockerfile`: the packages of Kata's
kernel builder on the same Ubuntu, the base pinned by digest and the
toolchain by package version), natively on the target architecture:

```
task build          # this host's architecture, into out/
task source         # the corresponding source tar, into out/
```

or directly: `docker build -t kiki-kernel-builder .` then
`docker run --rm -v "$PWD:/kernel:ro" -v "$PWD/out:/out" kiki-kernel-builder /kernel/build.sh kernel arm64 /out`.
An arm64 build takes about 5 minutes on an Apple M5 Max under OrbStack;
amd64 builds natively on an x86_64 Linux host. `WORKDIR` keeps the Kata
checkout and the Linux tarball between runs; it must be on a
case-sensitive filesystem (Linux's tree has both `xt_DSCP.c` and
`xt_dscp.c`), so on macOS make it a Docker volume
(`-e WORKDIR=/work -v kiki-kernel-work:/work`), not a bind mount.

`build.sh` checks out Kata's packaging scripts at `KATA_COMMIT`, checks that
`KATA_VERSION`, `KERNEL_VERSION` and `KATA_CONFIG_VERSION` are what that
commit says, fetches Linux's release tarball and checks it against
`LINUX_SHA256`, adds kiki's fragments to Kata's for the architecture, and
runs `build-kernel.sh -x -m` as Kata builds its default kernel
(`install_kernel` in `kata-deploy-binaries.sh`).

The build is reproducible: the timestamp, user and host are fixed
(`SOURCE_DATE_EPOCH` is the Kata commit's time), the build directory is
mapped out of the debug information (and so out of the build ID), pahole
encodes BTF on one thread, and the tars are written with sorted names,
fixed owners and mtimes. A local build of the same inputs in the same
builder gives the same bytes as CI.

The toolchain packages are pinned by version: when Ubuntu replaces one in
`jammy-updates` and the old one leaves the archive, building the builder
fails rather than build different bytes for the same release. Move the pin
and bump `KIKI_REVISION`.

## Publishing

Pushing the tag `v<release>` (kernel.env's release) runs the Build
workflow, which builds both architectures and the source, pushes the OCI
artifact, and creates the GitHub release. A release is published once: kiki
installs pin its blobs, so the workflow refuses to push a release whose
tag already exists with other blobs. A rerun (`gh run rerun`, or
`gh workflow run build.yml --ref v<release>`) that finds the same blobs
pushed finishes the GitHub release instead, so a run that failed halfway
can be rerun. A fix to the build files before anything was pushed means
moving the unpublished tag to the fixed commit, after cancelling the old
tag's runs (a run whose tag has moved refuses to publish). Run on a branch
(`gh workflow run build.yml`), the workflow only builds.

kiki fetches the blobs anonymously, so the package must be public. The
workflow pushes it with this public repository as its source, so the
package is linked here rather than to kiki's repository; if it is not
public, an organization owner makes it so, once, at
<https://github.com/orgs/ahimsalabs/packages/container/package/kiki-kernel/settings>.
The workflow warns when an anonymous pull fails.

Then, in kiki, move the pins in `internal/artifacts/pinned.go` to the
digests and sizes in the run's summary, and gate the change with kiki's
`task test:vm` and `task e2e`.

## Following Kata

kiki follows Kata's pinned kernel and does not pick kernel versions or
backport patches itself. The Kata bump workflow (`kata-bump.yml`, weekly
and by hand) compares the kernel version (`assets.kernel.version` in
`versions.yaml`) and `tools/packaging/kernel/kata_config_version` of Kata's
latest release with `kernel.env`. When either moves, it pushes a branch
`kata-bump/<kata tag>` that moves `KATA_VERSION`, `KATA_COMMIT`,
`KERNEL_VERSION`, `KATA_CONFIG_VERSION`, `LINUX_SHA256` and
`SOURCE_DATE_EPOCH` together and resets `KIKI_REVISION` to 1, starts a
build of the branch, and opens a pull request for it (or, while the
organization does not let Actions open pull requests, an issue linking
the branch). To follow it:

1. Check the branch's build passed: a fragment option Kconfig no longer
   offers fails it.
2. Merge, and push the tag `v<kernel>-<config>-kiki.1`.
3. Pin the new digests in kiki, as above.

Any other change to what goes into the kernel (a fragment, the builder
image) bumps `KIKI_REVISION` alone, and is released the same way.

## Licensing

The build files in this repository are Apache-2.0 (`LICENSE`), as is kiki.

The kernels they build are Linux, GPL-2.0-only, with Kata's patches. Each
release publishes, next to the binaries and in the same OCI artifact and
GitHub release, `kiki-kernel-<release>-source.tar`, the complete
corresponding source:

- `linux-<version>.tar.xz`, Linux's release tarball from kernel.org, as
  published (its SHA-256 is `LINUX_SHA256`);
- `kata-<kata version>/`: Kata's `tools/packaging/kernel` (`build-kernel.sh`,
  the config fragments, and the patches it applies, `patches/<series>.x/`)
  and `tools/packaging/scripts` at `KATA_COMMIT`, with `versions.yaml`
  (Apache-2.0; the patches are GPL-2.0, as the kernel);
- `kiki-kernel/`: this repository's build files at the release.

Each architecture's exact `.config` is published beside its binary
(`config-<release>` in the tar, and `config-<release>-<arch>`), and
`buildinfo-<release>` names the inputs and the toolchain. To rebuild the
published binaries from the source tar alone, with no network, unpack it
and run its `kiki-kernel/build.sh` in the builder image
(`kiki-kernel/Dockerfile`): run from there, it takes Kata's scripts and
Linux's tarball from beside it rather than fetching them:

```
mkdir src && tar -xf kiki-kernel-<release>-source.tar -C src
docker build -t kiki-kernel-builder src/kiki-kernel
docker run --rm --network none -v "$PWD/src:/src:ro" -v "$PWD/out:/out" \
  kiki-kernel-builder /src/kiki-kernel/build.sh kernel amd64 /out
```
