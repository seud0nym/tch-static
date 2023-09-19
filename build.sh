#!/bin/bash

[ -z "$*" ] && __SCRIPTS="$(find scripts -maxdepth 1 -type f ! -name README.md -exec basename {} \;)" || __SCRIPTS="$*"

__BASE_DIR=$(cd $(dirname $0) && pwd)
__PACKAGES=""

__default_conffiles() {
cat <<"CNF"
CNF
}

__default_postinst() {
cat <<"POI"
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_postinst $0 $@
POI
}

__default_prerm() {
cat <<"PRR"
#!/bin/sh
[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
. ${IPKG_INSTROOT}/lib/functions.sh
default_prerm $0 $@
PRR
}

check_dependencies() { # Parameters: none
  local __SCRIPT
  for __SCRIPT in $__SCRIPTS; do
    source scripts/${__SCRIPT}
    eval ${__SCRIPT}_dependencies
  done
  [ -n "$__PACKAGES" ] && apt install -y $__PACKAGES
}

check_package() { # Parameters: executable package
  which $1 >/dev/null || __PACKAGES="$__PACKAGES $2"
}

fetch_latest() { # Parameters: none
  if [ -d .git ]; then
    git fetch
    git gc
    git reset --hard HEAD
    git merge
    git fetch --tags
    __VERSION=$(git describe --tags `git rev-list --tags --max-count=1`)
    git checkout $__VERSION
  fi
}

main() { # Parameters: none
  for __SCRIPT in $__SCRIPTS; do
    ${__SCRIPT}_pushd
      fetch_latest
      [ -x ./autogen.sh ] && ./autogen.sh
      [ -x ./configure ]  && env FORCE_UNSAFE_CONFIGURE=1 CFLAGS="-static -Os -ffunction-sections -fdata-sections" LDFLAGS='-Wl,--gc-sections' ./configure $(eval echo -n \$${__SCRIPT}_configure_options)
      make $(eval echo -n \$${__SCRIPT}_make_options) -j $(nproc)
      make_package $__SCRIPT $__VERSION $(eval echo -n \$${__SCRIPT}_binaries)
    popd
  done
}

make_ipk() {
  ${__BASE_DIR}/make_ipk.sh "$2" "."
  local arch="$1"
  local ipk="$(basename $2)"
  local sha256="$(sha256sum "$2" | cut -d" " -f1)"
  local size="$(du --bytes $2 | cut -f1)"
  sed -e "/^Installed-Size:/a\Filename: $(basename $ipk)\nSize: ${size}\nSHA256sum: ${sha256}" control >> $__BASE_DIR/repository/${arch}/packages/Packages
  echo "" >> "$__BASE_DIR/repository/${arch}/packages/Packages"
  ${__BASE_DIR}/usign -S -m "$__BASE_DIR/repository/${arch}/packages/Packages" -s ${__BASE_DIR}/tch-static-private.key -x "$__BASE_DIR/repository/${arch}/packages/Packages.sig"
  gzip -fk "$__BASE_DIR/repository/${arch}/packages/Packages"
  rm -f control.tar control.tar.gz data.tar data.tar.gz packagetemp.tar
}

make_package() { # Parameters: script version binary [binary ...]
  local script="$1"
  local version="$2"
  local arch 
  local size=0
  local binary
  shift 2

  [ -e /tmp/__make_static_package ] && rm -rf /tmp/__make_static_package
  mkdir -p /tmp/__make_static_package/usr/bin

  for binary in $*; do
    strip_and_compress $binary
    cp -p $binary /tmp/__make_static_package/usr/bin/
    chmod +x /tmp/__make_static_package/usr/bin/$binary
    size=$(( $size + $(du --bytes "/tmp/__make_static_package/usr/bin/$binary" | cut -f1) ))
  done

  pushd /tmp/__make_static_package

  echo "2.0" > debian_binary
  { [ "$(type -t ${script}_conffiles)" == "function" ] && eval echo -n \$${script}_conffiles || __default_conffiles; } > conffiles
  { [ "$(type -t ${script}_postinst)" == "function" ]  && eval echo -n \$${script}_postinst  || __default_postinst;  } > postinst
  { [ "$(type -t ${script}_prerm)" == "function" ]     && eval echo -n \$${script}_prerm     || __default_prerm;     } > prerm

  chmod +x postinst
  chmod +x prerm

  cat <<CTL > control
Package: ${script}-static
Version: $version
Depends: $(eval echo -n \$${script}_Depends)
License: $(eval echo -n \$${script}_License)
Section: $(eval echo -n \$${script}_Section)
Architecture: 
Installed-Size: $size
Description: $(eval echo -n "\$${script}_Description")
CTL
  sed -e '/^Depends: *$/d' -i control

  for arch in arm_cortex-a9 arm_cortex-a53; do
    [ ! -d $__BASE_DIR/repository/${arch}/packages ] && mkdir -p $__BASE_DIR/repository/${arch}/packages
    [ ! -e $__BASE_DIR/repository/${arch}/packages/Packages ] && touch $__BASE_DIR/repository/${arch}/packages/Packages
    if [ -e $__BASE_DIR/repository/${arch}/packages/${script}-static_[^_]*_${arch}.ipk ]; then
      rm -rf $__BASE_DIR/repository/${arch}/packages/${script}-static_[^_]*_${arch}.ipk
      sed -e "/^Package: $script-static\$/,/^\$/d" -i $__BASE_DIR/repository/${arch}/packages/Packages
    fi
    sed -e "s/^Architecture:.*\$/Architecture: $arch/" -i control
    make_ipk $arch "${__BASE_DIR}/repository/${arch}/packages/${script}-static_${version}_${arch}.ipk"
  done
  
  popd
}

popd_build_directory() { # Parameters: none
  popd
}

pushd_build_directory() { # Parameters: none
  if [ ! -d build ]; then
    mkdir build
  fi
  pushd build
}

strip_and_compress() { # Parameters: executable
  strip -s -R .comment --strip-unneeded $1
  upx --ultra-brute $1
}

check_package git git
check_package gcc gcc
check_package make make
check_package autoreconf autoconf
check_package automake automake
check_package upx upx-ucl
check_dependencies

pushd_build_directory
main
popd_build_directory
