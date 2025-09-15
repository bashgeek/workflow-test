#!/bin/bash
set -euxo pipefail

export createrepo="createrepo_c"
export DEBIAN_FRONTEND=noninteractive
export DEBIAN_PRIORITY=critical
#export GPG_SIGNING_KEY="${GPG_SIGNING_KEY:-E617DCD4065C2AFC0B2CF7A7BA8BC08C0F691F94}"
export GPG_SIGNING_KEY="${GPG_SIGNING_KEY:-E83853A942C9BC0AEBFBF6C1101E0B17B596C6A5}"

if ! command -v sudo 2>/dev/null ; then
    # Shim sudo to support running in a container without it.
    #
    # $ podman run --mount "type=bind,source=$PWD,destination=/openbao" --workdir /openbao -it ubuntu:latest bash /openbao/scripts/genrepos.sh
    function sudo() {
        "$@"
    }
fi

function install_deps() {(
    sudo apt update
    sudo apt install -y wget jq curl tree dpkg-dev reprepro gunzip
    build_createrepo
    "$createrepo" --version
)}

# createrepo-c in official Ubuntu repo is very old, build it ourselve
function build_createrepo() {
    (
        sudo apt install -y libcurl4-openssl-dev libbz2-dev libxml2-dev libssl-dev zlib1g-dev pkg-config libglib2.0-dev liblzma-dev libsqlite3-dev librpm-dev libzstd-dev python3-dev cmake
        wget https://github.com/rpm-software-management/createrepo_c/archive/refs/tags/1.2.1.tar.gz -O /tmp/createrepo/source.tar.gz
        cd /tmp/createrepo
        gunzip source.tar.gz
        mkdir build && cd build && cmake ..
        make -j
    )

    createrepo="/tmp/createrepo/build/src/createrepo_c"
}


# Map architectures from Goreleaser to RPM ones
function map_arch_rpm() {
  case "$1" in
    amd64) echo "x86_64" ;;
    arm64) echo "aarch64" ;;
    armv6) echo "armv6hl" ;;
    armv7) echo "armv7hl" ;;
    ppc64le) echo "ppc64le" ;;
    riscv64) echo "riscv64" ;;
    s390x) echo "s390x" ;;
    *) echo "$1" ;;
  esac
}

function fetch_release_info() {
    curl -sSL \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      https://api.github.com/repos/openbao/openbao/releases > /tmp/release.json
}

# Build RPM repositories, one for each arch. Don't re-download packages
# that already exist.
function build_repos_rpms() {(
    local repo_base="build/repos/linux/rpm"

    # Download the release RPMs.
    jq -r '.[0] | .. | .browser_download_url? | select(. != null)' < /tmp/release.json |
        sed '/\(alpha\|beta\)/d' |
        grep -i '\.rpm$' |
    while read -r rpm; do
        local arch
        local name
        arch="$(grep -o '_linux_[a-zA-Z0-9]*\.rpm' <<< "$rpm" | sed 's/\(_linux_\|\.rpm$\)//g')"
        arch="$(map_arch_rpm "$arch")"
        name="$(basename "$rpm")"

        local dir="$repo_base/$arch"
        mkdir -p "$dir"
        wget --no-verbose "$rpm" --output-document "$dir/$name"
    done

    # Build the RPM repository
    for dir in "$repo_base"/*; do
        (
            cd "$dir"
            "$createrepo" .
        )
    done
)}

# Build Debian repositories.
function build_repos_deb() {(
    local repo_base="build/repos/linux/deb"
    mkdir -p "$repo_base"
    cd $repo_base

    # Create the reprepro configuration.
    local conf_base="conf"
    mkdir -p "$conf_base"
    cat > "$conf_base/distributions" <<_EOF
Origin: OpenBao - Official
Label: OpenBao
Suite: stable
Codename: stable
Architectures: amd64 armel armhf arm64 ppc64el riscv64 s390x
Components: main
Description: Official apt repository for OpenBao
SignWith: $GPG_SIGNING_KEY
_EOF

    # Download the release DEBs and add them.
    jq -r '.[0] | .. | .browser_download_url? | select(. != null)' < /tmp/release.json |
        sed '/\(alpha\|beta\)/d' |
        grep -i '\.deb$' |
    while read -r deb; do
        local name
        name="$(basename "$deb")"

        wget --no-verbose "$deb" --output-document "$name"
        reprepro --basedir . --delete --component=main --ignore=undefinedtarget includedeb stable "$name"
    done
)}

# Build all repositories
function build_repos() {(
    build_repos_rpms
    build_repos_deb

    # Arch repositories cannot be built as repo-add from pacman is not built
    # for Ubuntu or distributed separately from Arch.

    tree build/repos
    du -h --max-depth=1 build/repos
)}

function main() {(
    mkdir -p build/repos
    install_deps
    fetch_release_info
    build_repos
)}
main "$@"