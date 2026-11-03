#!/usr/bin/env bash
# Move kernel.env to the newest point release of the pinned longterm line.
#
#	scripts/bump-kernel.sh [BODYFILE]
#
# Reads the newest release of KERNEL_VERSION's series (6.18.x) from
# kernel.org's releases.json, and when it is newer than KERNEL_VERSION:
# takes the tarball's SHA-256 from the series' sha256sums.asc after
# checking that file's PGP signature against keys/kernel-org-autosigner.asc
# (kernel.org's checksum autosigner, fingerprint below), rewrites
# KERNEL_VERSION and LINUX_SHA256 in kernel.env, resets KIKI_REVISION to 1,
# and writes a pull request description to BODYFILE. Prints the new version
# on stdout; prints nothing and changes nothing when there is none.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
body="${1:-/dev/null}"
# kernel.org's checksum autosigner. The key is published at
# https://git.kernel.org/pub/scm/docs/kernel/pgpkeys.git (keys/632D3A06589DA6B1.asc).
signer=B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1

die() {
	echo "bump-kernel.sh: $*" >&2
	exit 1
}

# shellcheck source=kernel.env
source "${here}/kernel.env"
series="${KERNEL_VERSION%.*}"
major="${KERNEL_VERSION%%.*}"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

curl --fail --silent --show-error --location -o "${tmp}/releases.json" https://www.kernel.org/releases.json
# The newest release of the series, whichever moniker kernel.org gives it
# now; only a series that has left the list is an error.
latest="$(jq -r --arg s "${series}." '[.releases[] | select(.version | startswith($s))] | map(.version) | .[]' "${tmp}/releases.json" | sort -V | tail -1)"
[[ ${latest} =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "kernel.org's releases.json lists no ${series} release (end of life?)"
moniker="$(jq -r --arg v "${latest}" '.releases[] | select(.version == $v) | .moniker' "${tmp}/releases.json")"
if [[ ${moniker} != longterm ]]; then
	echo "bump-kernel.sh: warning: kernel.org lists ${latest} as ${moniker}, not longterm" >&2
fi
if [[ ${latest} == "${KERNEL_VERSION}" || "$(printf '%s\n%s\n' "${KERNEL_VERSION}" "${latest}" | sort -V | tail -1)" != "${latest}" ]]; then
	exit 0
fi

curl --fail --silent --show-error --location -o "${tmp}/sha256sums.asc" "https://cdn.kernel.org/pub/linux/kernel/v${major}.x/sha256sums.asc"
export GNUPGHOME="${tmp}/gnupg"
mkdir -m 700 "${GNUPGHOME}"
gpg --batch --quiet --import "${here}/keys/kernel-org-autosigner.asc"
# VALIDSIG names the primary key's fingerprint last; gpg's exit status
# alone would accept any key in the keyring.
status="$(gpg --batch --status-fd 1 --verify "${tmp}/sha256sums.asc" 2>/dev/null)" ||
	die "sha256sums.asc does not verify"
grep -q "^\[GNUPG:\] VALIDSIG .* ${signer}\$" <<<"${status}" ||
	die "sha256sums.asc is not signed by ${signer}"
# Only the signed text counts.
gpg --batch --quiet --decrypt "${tmp}/sha256sums.asc" >"${tmp}/sha256sums" 2>/dev/null || die "cannot read the signed text"
sum="$(awk -v f="linux-${latest}.tar.xz" '$2 == f {print $1}' "${tmp}/sha256sums")"
[[ ${sum} =~ ^[0-9a-f]{64}$ ]] || die "the signed sha256sums.asc does not list linux-${latest}.tar.xz"

sed -i \
	-e "s/^KERNEL_VERSION=.*/KERNEL_VERSION=${latest}/" \
	-e "s/^KIKI_REVISION=.*/KIKI_REVISION=1/" \
	-e "s/^LINUX_SHA256=.*/LINUX_SHA256=${sum}/" \
	"${here}/kernel.env"

cat >"${body}" <<-EOF
	Moves kernel.env from Linux ${KERNEL_VERSION} to ${latest}, the newest release of the ${series} line on kernel.org, and resets \`KIKI_REVISION\` to 1. \`LINUX_SHA256\` is \`linux-${latest}.tar.xz\`'s line in kernel.org's \`sha256sums.asc\`, whose PGP signature was verified against the checksum autosigner key ${signer} (\`keys/kernel-org-autosigner.asc\`).

	Kata's config version and patches are unchanged. Before merging (README.md, "Following Kata and the longterm line"): check that the build of this branch passed (a patch that no longer applies, or a fragment option Kconfig drops, fails it), drop the patches the new release has, then merge and push the tag \`v${latest}-${KATA_CONFIG_VERSION}-kiki.1\` to publish.
EOF
echo "${latest}"
