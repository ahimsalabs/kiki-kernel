#!/usr/bin/env bash
# Build kiki's guest kernel: Kata's kernel at kernel.env's pins, configured
# by Kata's build-kernel.sh from Kata's fragments plus kiki's (fragments/).
# Run it in the builder image (Dockerfile here), natively on the target
# architecture:
#
#	build.sh kernel amd64|arm64 OUTDIR
#	build.sh source OUTDIR
#
# kernel writes OUTDIR/kiki-kernel-<release>-<arch>.tar.zst, which holds at
# its root vmlinux-<release> (amd64: the PVH ELF; arm64: the Image),
# config-<release> and buildinfo-<release>, and those members unpacked
# beside it. source writes OUTDIR/kiki-kernel-<release>-source.tar, the
# complete corresponding source (GPL-2.0 §3): Linux's release tarball,
# Kata's kernel packaging (build-kernel.sh, its config fragments and
# patches, the scripts it sources) at KATA_COMMIT, and this repository's
# build files.
#
# WORKDIR (default: a temp dir) keeps the Kata checkout and the Linux
# tarball between runs. It must be on a case-sensitive filesystem: Linux's
# tree has names that differ only in case (xt_DSCP.c, xt_dscp.c).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=kernel.env
source "${here}/kernel.env"
release="${KERNEL_VERSION}-${KATA_CONFIG_VERSION}-kiki.${KIKI_REVISION}"
linux="linux-${KERNEL_VERSION}.tar.xz"

die() {
	echo "build.sh: $*" >&2
	exit 1
}

usage() {
	die "usage: build.sh kernel amd64|arm64 OUTDIR | build.sh source OUTDIR"
}

# prepare fetches and checks the inputs into ${work}: a fresh copy of
# Kata's packaging scripts at the pinned commit (${kata}, ${pkg}), and
# Linux's tarball. Run from an unpacked source tar, where this script is
# kiki-kernel/build.sh beside kata-<version>/ and linux-<version>.tar.xz,
# it takes both from there and needs no network.
prepare() {
	work="${WORKDIR:-$(mktemp -d)}"
	mkdir -p "${work}"
	# The physical path: build-kernel.sh resolves the tree's, and the
	# prefix maps below must name the same one.
	work="$(cd "${work}" && pwd -P)"
	# Every run rewrites ${work}/kata, so one run at a time: a second run
	# could otherwise remove kiki's fragments from under a kernel build,
	# which would then build Kata's config under kiki's release. A
	# WORKDIR that is OUTDIR is locked already.
	if [[ ! "${work}/.lock" -ef "${out_lock}" ]]; then
		exec 9>"${work}/.lock"
		flock -n 9 || die "another build.sh is using ${work}"
	fi
	rm -f "${work}/.case" "${work}/.CASE"
	touch "${work}/.case"
	if [[ -e "${work}/.CASE" ]]; then
		rm -f "${work}/.case"
		die "${work} is on a case-insensitive filesystem; set WORKDIR to a case-sensitive one"
	fi
	rm -f "${work}/.case"

	local bundle="${here}/.." src
	if [[ -d "${bundle}/kata-${KATA_VERSION}" && -f "${bundle}/${linux}" ]]; then
		# An unpacked source tar: everything is here.
		src="${bundle}/kata-${KATA_VERSION}"
		if [[ ! "${bundle}/${linux}" -ef "${work}/${linux}" ]]; then
			cp "${bundle}/${linux}" "${work}/${linux}"
		fi
	else
		src="${work}/kata-${KATA_COMMIT}"
		if [[ ! -d ${src} ]]; then
			rm -rf "${src}.tmp"
			git clone --quiet --filter=blob:none --no-checkout \
				https://github.com/kata-containers/kata-containers "${src}.tmp"
			git -C "${src}.tmp" sparse-checkout set --no-cone /versions.yaml /tools/packaging/kernel/ /tools/packaging/scripts/
			git -C "${src}.tmp" checkout --quiet "${KATA_COMMIT}"
			mv "${src}.tmp" "${src}"
		fi
		[[ "$(git -C "${src}" rev-parse "${KATA_VERSION}^{commit}")" == "${KATA_COMMIT}" ]] ||
			die "Kata tag ${KATA_VERSION} is not ${KATA_COMMIT}"
		if [[ "$(git -C "${src}" rev-parse HEAD)" != "${KATA_COMMIT}" ]] || ! git -C "${src}" diff --quiet HEAD --; then
			die "${src} is not a clean checkout of ${KATA_COMMIT}"
		fi
	fi
	# A fresh copy each run: kernel below adds kiki's fragments to Kata's,
	# and build-kernel.sh writes beside them.
	kata="${work}/kata"
	rm -rf "${kata}"
	mkdir -p "${kata}/tools/packaging"
	cp -p "${src}/versions.yaml" "${kata}/"
	cp -pR "${src}/tools/packaging/kernel" "${src}/tools/packaging/scripts" "${kata}/tools/packaging/"
	pkg="${kata}/tools/packaging/kernel"
	[[ "$(cat "${pkg}/kata_config_version")" == "${KATA_CONFIG_VERSION}" ]] ||
		die "Kata ${KATA_VERSION} has kata_config_version $(cat "${pkg}/kata_config_version"), kernel.env says ${KATA_CONFIG_VERSION}"
	# assets.kernel.version, without yq: the first version line after
	# "  kernel:".
	local kata_kernel
	kata_kernel="$(awk '/^  kernel:$/ {k=1} k && /^    version:/ {gsub(/[" v]/, "", $2); print $2; exit}' "${kata}/versions.yaml")"
	[[ ${kata_kernel} == "${KERNEL_VERSION}" ]] ||
		die "Kata ${KATA_VERSION} pins kernel ${kata_kernel}, kernel.env says ${KERNEL_VERSION}"

	# build-kernel.sh takes the tarball and its checksum line from its
	# working directory, so the pinned digest is the one it checks.
	if [[ ! -f "${work}/${linux}" ]] || ! (cd "${work}" && echo "${LINUX_SHA256}  ${linux}" | sha256sum -c --status); then
		curl --fail --silent --show-error --location -o "${work}/${linux}.tmp" \
			"https://cdn.kernel.org/pub/linux/kernel/v${KERNEL_VERSION%%.*}.x/${linux}"
		mv "${work}/${linux}.tmp" "${work}/${linux}"
	fi
	echo "${LINUX_SHA256}  ${linux}" >"${work}/${linux}.sha256"
	(cd "${work}" && sha256sum -c --quiet "${linux}.sha256") || die "${linux} does not match LINUX_SHA256"
}

# tarball writes a reproducible tar of dir's named members to stdout.
tarball() {
	local dir="$1"
	shift
	tar --sort=name --format=posix \
		--pax-option=exthdr.name=%d/PaxHeaders/%f,delete=atime,delete=ctime \
		--owner=0 --group=0 --numeric-owner --mtime="@${SOURCE_DATE_EPOCH}" \
		-C "${dir}" -cf - "$@"
}

build_kernel() {
	local arch="$1" out="$2" kata_arch frag_arch
	case "${arch}" in
	amd64) kata_arch=x86_64 frag_arch=x86_64 ;;
	arm64) kata_arch=aarch64 frag_arch=arm64 ;;
	*) die "unknown architecture ${arch}" ;;
	esac
	case "$(uname -m)" in
	x86_64) [[ ${arch} == amd64 ]] || die "build ${arch} on an ${arch} host" ;;
	aarch64) [[ ${arch} == arm64 ]] || die "build ${arch} on an ${arch} host" ;;
	esac
	prepare

	# build-kernel.sh merges every .conf in the architecture's fragment
	# directory with Kata's common ones. Its own check that every option
	# asked for is in the final config does not work at KATA_COMMIT (an
	# empty line in its whitelist.conf matches every missing option), so
	# kiki's options are checked below, after setup.
	local frags="${pkg}/configs/fragments/${frag_arch}" kiki_frags=("${here}/fragments/common.conf")
	cp "${here}/fragments/common.conf" "${frags}/kiki.conf"
	if [[ -f "${here}/fragments/${frag_arch}.conf" ]]; then
		cp "${here}/fragments/${frag_arch}.conf" "${frags}/kiki-${frag_arch}.conf"
		kiki_frags+=("${here}/fragments/${frag_arch}.conf")
	fi

	export KBUILD_BUILD_TIMESTAMP="@${SOURCE_DATE_EPOCH}"
	export KBUILD_BUILD_USER=kiki KBUILD_BUILD_HOST=kiki KBUILD_BUILD_VERSION=1
	export SOURCE_DATE_EPOCH
	# pahole before 1.26 encodes BTF in a different order run to run when
	# it runs on several threads, and the kernel's Makefile.btf passes it
	# make's -j: so pahole comes first on PATH as itself on one thread.
	local bin="${work}/bin"
	mkdir -p "${bin}"
	cat >"${bin}/pahole" <<-'EOF'
		#!/usr/bin/env bash
		args=()
		for a in "$@"; do
			[[ ${a} == -j* ]] || args+=("${a}")
		done
		exec /usr/bin/pahole "${args[@]}"
	EOF
	chmod +x "${bin}/pahole"
	export PATH="${bin}:${PATH}"
	# As Kata builds its default kernel (install_kernel in
	# kata-deploy-binaries.sh): -x and -m add the confidential-guest and
	# measured-rootfs fragments its published config was built with, so
	# without kiki's fragments the config is Kata's to the byte.
	local tree="${work}/tree-${KERNEL_VERSION}"
	rm -rf "${tree}"
	# The tree's path, which WORKDIR picks, would otherwise go into the
	# DWARF (the compile directory, from gcc and from gas), which the
	# linker hashes into the build ID that the published vmlinux and Image
	# carry. gcc 11 hands gas -fdebug-prefix-map but not -ffile-prefix-map.
	local map="-ffile-prefix-map=${tree}=. -fdebug-prefix-map=${tree}=."
	export KCFLAGS="${map}" KAFLAGS="${map}"
	(
		cd "${work}"
		"${pkg}/build-kernel.sh" -a "${kata_arch}" -v "${KERNEL_VERSION}" -x -m -f -k "${tree}" setup
	)
	# Every assignment in kiki's fragments must be in the config as
	# written: an option that Kconfig drops or changes fails the build.
	local line missing=()
	while IFS= read -r line; do
		grep -qxF -- "${line}" "${tree}/.config" || missing+=("${line}")
	done < <(grep -hE '^CONFIG_[A-Za-z0-9_]+=' "${kiki_frags[@]}")
	((${#missing[@]} == 0)) || die "the config does not have kiki's ${missing[*]}"
	(
		cd "${work}"
		"${pkg}/build-kernel.sh" -a "${kata_arch}" -v "${KERNEL_VERSION}" -x -m -k "${tree}" build
	)

	local stage="${work}/stage-${arch}"
	rm -rf "${stage}"
	mkdir -p "${stage}"
	if [[ ${arch} == amd64 ]]; then
		# The PVH ELF without its DWARF, which DEBUG_INFO_BTF needs only to
		# generate .BTF. The symbol table stays, as in Kata's vmlinux.
		strip --strip-debug -o "${stage}/vmlinux-${release}" "${tree}/vmlinux"
	else
		cp "${tree}/arch/arm64/boot/Image" "${stage}/vmlinux-${release}"
	fi
	cp "${tree}/.config" "${stage}/config-${release}"
	cat >"${stage}/buildinfo-${release}" <<-EOF
		release: ${release}
		arch: ${arch}
		kata: ${KATA_VERSION} ${KATA_COMMIT} (tools/packaging/kernel, kata_config_version ${KATA_CONFIG_VERSION})
		linux: ${linux} sha256 ${LINUX_SHA256}
		source: ghcr.io/ahimsalabs/kiki-kernel:${release}, layer kiki-kernel-${release}-source.tar
		build files: https://github.com/ahimsalabs/kiki-kernel/tree/v${release}
		gcc: $(gcc --version | head -1)
		ld: $(ld --version | head -1)
		pahole: $(pahole --version)
		SOURCE_DATE_EPOCH: ${SOURCE_DATE_EPOCH}
	EOF
	chmod 0444 "${stage}"/*
	touch -d "@${SOURCE_DATE_EPOCH}" "${stage}"/*

	local name="kiki-kernel-${release}-${arch}.tar.zst"
	tarball "${stage}" "vmlinux-${release}" "config-${release}" "buildinfo-${release}" |
		zstd -q -19 -T1 >"${out}/${name}.tmp"
	mv "${out}/${name}.tmp" "${out}/${name}"
	for f in vmlinux config buildinfo; do
		rm -f "${out}/${f}-${release}"
		cp -p "${stage}/${f}-${release}" "${out}/${f}-${release}"
	done
	(cd "${out}" && sha256sum "${name}" "vmlinux-${release}" "config-${release}" && ls -ln "${name}" "vmlinux-${release}" "config-${release}")
}

build_source() {
	local out="$1"
	prepare
	local stage="${work}/stage-source"
	rm -rf "${stage}"
	mkdir -p "${stage}/kata-${KATA_VERSION}/tools/packaging" "${stage}/kiki-kernel"
	cp -p "${work}/${linux}" "${stage}/"
	cp -p "${kata}/versions.yaml" "${stage}/kata-${KATA_VERSION}/"
	cp -pR "${pkg}" "${kata}/tools/packaging/scripts" "${stage}/kata-${KATA_VERSION}/tools/packaging/"
	(cd "${here}" && cp -pR README.md LICENSE kernel.env build.sh Dockerfile fragments "${stage}/kiki-kernel/")
	# The checkout's umask must not reach the tar: only whether a file is
	# executable does.
	chmod -R u=rwX,go=rX "${stage}"
	find "${stage}" -exec touch -h -d "@${SOURCE_DATE_EPOCH}" {} +
	local name="kiki-kernel-${release}-source.tar"
	tarball "${stage}" . >"${out}/${name}.tmp"
	mv "${out}/${name}.tmp" "${out}/${name}"
	(cd "${out}" && sha256sum "${name}" && ls -ln "${name}")
}

[[ $# -ge 1 ]] || usage
# lock_out takes OUTDIR for the run: two runs writing the same files
# there would corrupt them.
lock_out() {
	out_lock="$(cd "$1" && pwd -P)/.lock"
	exec 8>"${out_lock}"
	flock -n 8 || die "another build.sh is writing to $1"
}

case "$1" in
kernel)
	[[ $# -eq 3 ]] || usage
	mkdir -p "$3"
	lock_out "$3"
	build_kernel "$2" "$(cd "$3" && pwd)"
	;;
source)
	[[ $# -eq 2 ]] || usage
	mkdir -p "$2"
	lock_out "$2"
	build_source "$(cd "$2" && pwd)"
	;;
*) usage ;;
esac
