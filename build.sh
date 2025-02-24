#!/bin/bash
GREEN='\033[1;32m'
GREY='\033[90m'
ORANGE='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

__PKG_ONLY=N
__REBUILD=N
__THIS_ARCH=$(uname -m)

musl() {
  case "$1" in
    arm) echo "arm-linux-musleabi";;
    aarch64) echo "aarch64-linux-musl";;
    *) echo -e "${RED}$(date +%X) ==> ERROR: Unknown architecture '$1'!${NC}" 1>&2; exit 2;;
  esac
}

if [ $__THIS_ARCH == x86_64 -o $__THIS_ARCH == aarch64 ]; then
  __MUSL_ARCH=(arm aarch64)
  __OWRT_ARCH=(arm_cortex-a9 arm_cortex-a53)
  __MUSL_PRFX=()
  __MUSL_PRFX+=($(eval musl ${__MUSL_ARCH[0]}))
  __MUSL_PRFX+=($(eval musl ${__MUSL_ARCH[1]}))
elif [[ $__THIS_ARCH =~ ^armv[567] ]]; then
  __MUSL_ARCH=(arm)
  __OWRT_ARCH=(arm_cortex-a9)
else
  echo -e "${RED}$(date +%X) ==> ERROR: Unsupported build machine: ${__THIS_ARCH}!${NC}"
  exit 2
fi

echo -e "${GREEN}$(date +%X) ==> INFO:  Checking for required keys....${GREY}[$(pwd)]${NC}"
[ -e keys/seud0nym-private.key ] || { echo -e "${RED}$(date +%X) ==> ERROR: Private key not found!${NC}"; exit 2; }

case $(nproc) in
	1|2) __JOBS=1;;
	3|4) __JOBS=2;;
	*)	 __JOBS=$(( $(nproc) - 2 ));;
esac
echo -e "${GREY}$(date +%X) ==> DEBUG: Maximum make jobs: $__JOBS${NC}"

git submodule init
git submodule update

[ ! -d toolchains ] && mkdir toolchains
for I in $(seq 0 $((${#__MUSL_PRFX[@]} - 1))); do
  __TARGET=${__MUSL_PRFX[$I]}
  if [ -n "$(find toolchains/ -name ${__TARGET}-gcc)" ]; then
    echo -e "${GREEN}$(date +%X) ==> INFO:  Found $__TARGET toolchain${GREY}[$(pwd)]${NC}"
  else
    echo -e "${GREEN}$(date +%X) ==> INFO:  Updating musl-cross-make submodule...${GREY}[$(pwd)]${NC}"
    pushd musl-cross-make || exit 2
      git fetch
      git gc
      git reset --hard HEAD
      git merge origin/master
    popd #musl-cross-make
    echo -e "${GREEN}$(date +%X) ==> INFO:  Building $__TARGET toolchain...${GREY}[$(pwd)]${NC}"
    echo "TARGET = $__TARGET" > musl-cross-make/config.mak
    make -C musl-cross-make clean --silent
    make -C musl-cross-make -j $__JOBS --silent || exit 2
    echo -e "${GREEN}$(date +%X) ==> INFO:  Installing $__TARGET toolchain...${GREY}[$(pwd)]${NC}"
    make -C musl-cross-make OUTPUT="/" DESTDIR="$(pwd)/toolchains" install --silent
  fi
done

if [ ! -x bin/usign ]; then
  pushd usign || exit 2
    git fetch
    git gc
    git reset --hard HEAD
    git merge origin/master
    rm -rf build
    mkdir build
    pushd build
      echo -e "${GREEN}$(date +%X) ==> INFO:  Generating build system for usign...${GREY}[$(pwd)]${NC}"
      cmake ..
      echo -e "${GREEN}$(date +%X) ==> INFO:  Building usign...${GREY}[$(pwd)]${NC}"
      make --silent || exit 2
    popd # build
  popd # usign
  cp usign/build/usign bin/usign
fi

echo -e "${GREEN}$(date +%X) ==> INFO:  Determining latest upx version....${GREY}[$(pwd)]${NC}"
__UPX_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/upx/upx/releases/latest)
__UPX_VER=$(basename $__UPX_URL | sed -e 's/^v//')
echo -e "${GREY}$(date +%X) ==> DEBUG: Latest upx version: $__UPX_VER${NC}"
if [ ! -x bin/upx -o "$(bin/upx -V 2>/dev/null | grep ^upx | grep -o '[0-9.]*')" != "$__UPX_VER" ]; then
  if [ $__THIS_ARCH == x86_64 ]; then
    __UPX_DIR="upx-${__UPX_VER}-amd64_linux"
  elif [ $__THIS_ARCH == aarch64 ]; then
    __UPX_DIR="upx-${__UPX_VER}-arm64_linux"
  elif [[ $__THIS_ARCH =~ ^armv[567] ]]; then
    __UPX_DIR="upx-${__UPX_VER}-arm_linux"
  fi
  curl -L https://github.com/upx/upx/releases/download/v${__UPX_VER}/${__UPX_DIR}.tar.xz -o /tmp/upx.tar.xz
  if [ -e /tmp/upx.tar.xz ]; then
    tar -C bin --strip-components=1 -xJf /tmp/upx.tar.xz ${__UPX_DIR}/upx
    rm -rf /tmp/upx.tar.xz
  else
    echo -e "${RED}$(date +%X) ==> ERROR: Failed to download upx v${__UPX_VER}!${NC}"
    exit 2
  fi
fi

__BASE_DIR=$(cd $(dirname $0) && pwd)
__PACKAGES=""

__default_conffiles() {
cat <<-"CNF"
CNF
}

__default_postinst() {
cat <<-"POI"
	#!/bin/sh
	[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
	[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
	. ${IPKG_INSTROOT}/lib/functions.sh
	default_postinst $0 $@
POI
}

__default_prerm() {
cat <<-"PRR"
	#!/bin/sh
	[ -s ${IPKG_INSTROOT}/lib/functions.sh ] || exit 0
	. ${IPKG_INSTROOT}/lib/functions.sh
	default_prerm $0 $@
PRR
}

fetch_latest() { # Parameters: none
  if [ -d .git ]; then
    git config --add advice.detachedHead false
    eval git reset --hard \$${__SCRIPT}_master_branch
    eval git checkout \$${__SCRIPT}_master_branch
    git fetch --tags
  fi
  __VERSION=$(eval ${__SCRIPT}_version)
  if [ -d .git ]; then
    git checkout $__VERSION
  fi
  [ "$(type -t ${__SCRIPT}_version_number)" == "function" ] && __VERSION=$(eval ${__SCRIPT}_version_number)
}

make_ipk() {
  ${__BASE_DIR}/bin/make_ipk.sh "$2" "."
  local arch="$1"
  local ipk="$(basename $2)"
  local sha256="$(sha256sum "$2" | cut -d" " -f1)"
  local size="$(du --bytes $2 | cut -f1)"
  local packages="$__BASE_DIR/repository/${arch}/packages/Packages"
  sed -e "/^Installed-Size:/a\Filename: ${ipk}\nSize: ${size}\nSHA256sum: ${sha256}" control >> $packages
  echo "" >> $packages
  sign_and_zip $packages
  ${__BASE_DIR}/bin/usign -S -m $packages -s ${__BASE_DIR}/keys/seud0nym-private.key -x ${packages}.sig
  gzip -fk $packages
  rm -f control.tar control.tar.gz data.tar data.tar.gz packagetemp.tar
}

make_package() { # Parameters: script version architecture binary [binary ...]
  local binary
  local script="$1"
  local version="$(echo $2 | sed -e 's/^v//')"
  local arch="$3"
  shift 3

	echo -e "${GREEN}$(date +%X) ==> INFO:  Packaging $script for $arch....${GREY}[$(pwd)]${NC}"

  [ -e /tmp/__make_static_package ] && rm -rf /tmp/__make_static_package
  mkdir -p /tmp/__make_static_package/usr/bin

  for binary in $*; do
    if [ ! -e $binary ]; then
    	echo -e "${RED}$(date +%X) ==> ERROR: Binary $binary not found! Skipping package build...${GREY}[$(pwd)]${NC}"
      return
    fi 
    [ -x $binary ] && strip_and_compress $binary
    cp -p $binary /tmp/__make_static_package/usr/bin/
    chmod +x /tmp/__make_static_package/usr/bin/$(basename $binary)
  done

  pushd /tmp/__make_static_package
		echo "2.0" > debian_binary
		{ [ "$(type -t ${script}_conffiles)" == "function" ] && eval printf \""\$(${script}_conffiles)"\" || __default_conffiles; } > conffiles
		{ [ "$(type -t ${script}_postinst)" == "function" ]  && eval printf \""\$(${script}_postinst)"\"  || __default_postinst;  } > postinst
		{ [ "$(type -t ${script}_prerm)" == "function" ]     && eval printf \""\$(${script}_prerm)"\"     || __default_prerm;     } > prerm
			[ "$(type -t ${script}_postrm)" == "function" ]    && eval printf \""\$(${script}_postrm)"\"                              > postrm
			[ "$(type -t ${script}_add_files)" == "function" ] && eval ${script}_add_files

		chmod +x postinst prerm
		[ -e postrm ] && chmod +x postrm

		#region control
		cat <<CTL > control
Package: ${script}-static
Version: $version
Depends: $(eval printf \""\$${script}_Depends"\")
License: $(eval printf \""\$${script}_License"\")
Section: $(eval printf \""\$${script}_Section"\")
Architecture: 
Installed-Size: $(du -c --bytes $(find . -mindepth 2 -type f) | tail -n1 | cut -f1)
Description: $(eval printf \""\$${script}_Description"\")
CTL
		sed -e '/^Depends: *$/d' -i control
		#endregion

		[ ! -d $__BASE_DIR/repository/${arch}/packages ] && mkdir -p $__BASE_DIR/repository/${arch}/packages
		[ ! -e $__BASE_DIR/repository/${arch}/packages/Packages ] && touch $__BASE_DIR/repository/${arch}/packages/Packages
		sed -e "s/^Architecture:.*\$/Architecture: $arch/" -i control
		make_ipk $arch "${__BASE_DIR}/repository/${arch}/packages/${script}-static_${version}_${arch}.ipk"

		[ -e postrm ] && rm postrm
  popd
}

sign_and_zip() { #Parameters: Packages_file_path
  local packages="$1"
  echo -e "${GREY}$(date +%X) ==> DEBUG: Signing and gzipping $1${NC}"
  ${__BASE_DIR}/bin/usign -S -m $packages -s ${__BASE_DIR}/keys/seud0nym-private.key -x ${packages}.sig
  gzip -fk $packages
}

strip_and_compress() { # Parameters: executable
  [ -x $1 ] || { echo -e "${RED}$(date +%X) ==> ERROR: Executable $1 not found!${NC}"; exit 2; }
	echo -e "${GREY}$(date +%X) ==> DEBUG: $__STRIP -s -R .comment -R .gnu.version --strip-unneeded $1${NC}"
	$__STRIP -s -R .comment -R .gnu.version --strip-unneeded $1
	echo -e "${GREY}$(date +%X) ==> DEBUG: $__BASE_DIR/bin/upx --ultra-brute $1${NC}"
	$__BASE_DIR/bin/upx --ultra-brute $1
}

if [ "$1" == "clean" ]; then
  shift
  echo -e "${GREEN}$(date +%X) ==> INFO:  Cleaning...${GREY}[$(pwd)]${NC}"
  rm -rf .work
  if [ $# == 0 ]; then
    rm -rf repository
  else
    for name in $*; do
      for pkg in $(find repository -name "$name-static_*.ipk"); do
        echo -e "${GREY}$(date +%X) ==> DEBUG: Removing $pkg${NC}"
        dir=$(dirname $pkg)
        rm $pkg
        sed -e "/^Package: $name-static$/,/^$/d" -i $dir/Packages
        sign_and_zip $dir/Packages
      done
    done
    unset name pkg dir
  fi
fi

echo -e "${GREEN}$(date +%X) ==> INFO:  Discovering scripts....${GREY}[$(pwd)]${NC}"
[ -z "$*" ] && __SCRIPTS="$(find scripts -maxdepth 1 -type f ! -name README.md -exec basename {} \; | sort | xargs)" || __SCRIPTS="$*"
echo -e "${GREY}$(date +%X) ==> DEBUG: $__SCRIPTS${NC}"
	
[ ! -d .work ] && mkdir .work
pushd .work
  chmod +x $__BASE_DIR/bin/*
  for __SCRIPT in $__SCRIPTS; do
		echo -e "${GREEN}$(date +%X) ==> INFO:  Loading $__SCRIPT....${GREY}[$(pwd)]${NC}"
		source ../scripts/$__SCRIPT
    [ -z $(eval echo \$${__SCRIPT}_master_branch) ] && eval ${__SCRIPT}_master_branch="master"

    __PATH="$PATH"
    for I in $(seq 0 $((${#__MUSL_ARCH[@]} - 1))); do
      __ARCH=${__MUSL_ARCH[$I]}
			__ARCH_BLD="$(eval echo \$${__SCRIPT}_${__ARCH})"
      if [ "$__ARCH_BLD" == "no" ]; then
        echo -e "${ORANGE}$(date +%X) ==> INFO:  Skipping build of $__SCRIPT for $__ARCH - ${__SCRIPT}_${__ARCH}=no!${GREY}[$(pwd)]${NC}"
        continue
      fi
			echo -e "${GREY}$(date +%X) ==> DEBUG: ${__SCRIPT}_${__ARCH}=${__ARCH_BLD}${NC}"
			echo -e "${GREEN}$(date +%X) ==> INFO:  Initialising $__SCRIPT build for $__ARCH....${GREY}[$(pwd)]${NC}"
      __TARGET=${__MUSL_PRFX[$I]}
			if [ -z "$__ARCH_BLD" ]; then
				export CC="${__TARGET}-gcc"
				echo -e "${GREY}$(date +%X) ==> DEBUG: CC=$CC${NC}"
				__BIN_DIR="$(readlink -f $(dirname $(find ../toolchains/ -name "$CC"))/..)/bin"
				echo -e "${GREY}$(date +%X) ==> DEBUG: __BIN_DIR=$__BIN_DIR${NC}"
				export PATH="$__BIN_DIR:$__PATH"
				__STRIP="$__BIN_DIR/strip"
	      [ -x "$__STRIP" ] || __STRIP="$(readlink -f $(find ../toolchains/${__TARGET}* -type f -executable -name '*strip' | head -n 1))"
			else
				__STRIP="strip"
			fi
      echo -e "${GREY}$(date +%X) ==> DEBUG: CC=$CC${NC}"
      echo -e "${GREY}$(date +%X) ==> DEBUG: STRIP=$__STRIP${NC}"
      echo -e "${GREEN}$(date +%X) ==> INFO:  Getting latest source for $__SCRIPT....${GREY}[$(pwd)]${NC}"
			eval ${__SCRIPT}_pushd $__BIN_DIR
				fetch_latest
				echo -e "${GREY}$(date +%X) ==> DEBUG: Latest version = $__VERSION${NC}"
				if [ -e ${__BASE_DIR}/repository/${__OWRT_ARCH[$I]}/packages/${__SCRIPT}-static_${__VERSION}_${__OWRT_ARCH[$I]}.ipk ]; then
					echo -e "${ORANGE}$(date +%X) ==> INFO:  Skipping build of $__SCRIPT for $__ARCH - Version $__VERSION ipk file already exists!${GREY}[$(pwd)]${NC}"
				else
          __PKG_DIR="$__BASE_DIR/repository/${__OWRT_ARCH[$I]}/packages"
          __OLD_PKG="$__PKG_DIR/${__SCRIPT}-static_[^_]*_${__OWRT_ARCH[$I]}.ipk"
          if [ -e $__OLD_PKG ]; then
            echo -e "${GREEN}$(date +%X) ==> INFO:  Removing old $__SCRIPT $__ARCH package....${GREY}[$(pwd)]${NC}"
            echo -e "${GREY}$(date +%X) ==> DEBUG: $__OLD_PKG${NC}"
            rm -f $__OLD_PKG
            sed -e "/^Package: $script-static$/,/^$/d" -i $__PKG_DIR/Packages
            sign_and_zip $__PKG_DIR/Packages
          fi
          echo -e "${GREEN}$(date +%X) ==> INFO:  Preparing $__SCRIPT build for $__ARCH....${GREY}[$(pwd)]${NC}"
          if [ -x autogen.sh ]; then
            ./autogen.sh
          elif [ -x bootstrap ]; then
            ./bootstrap
          elif [ -e configure.ac -a ! -e configure ]; then
            automake --add-missing
            autoreconf -fiv
            autoconf
          fi
          if [ -e Makefile.in -a ! -e Makefile ]; then
            automake
          fi
          if [ -x configure ]; then
            echo -e "${GREEN}$(date +%X) ==> INFO:  Configuring $__SCRIPT build for $__ARCH....${GREY}[$(pwd)]${NC}"
            export FORCE_UNSAFE_CONFIGURE=1
            export CFLAGS="-static -Os -ffunction-sections -fdata-sections"
            eval ./configure \$${__SCRIPT}_configure_options --host="${__TARGET}"
          fi
          if [ -e Makefile ]; then
            echo -e "${GREEN}$(date +%X) ==> INFO:  Building $__SCRIPT version $__VERSION for $__ARCH....${GREY}[$(pwd)]${NC}"
            make clean
            make reconfigure
            echo -e "${GREY}$(date +%X) ==> DEBUG: CPPFLAGS=$CPPFLAGS${NC}"
            echo -e "${GREY}$(date +%X) ==> DEBUG: LDFLAGS=$LDFLAGS${NC}"
            eval make \$${__SCRIPT}_make_options -j $__JOBS || exit 2
          fi
          eval make_package $__SCRIPT $__VERSION ${__OWRT_ARCH[$I]} \$${__SCRIPT}_binaries
				fi
			eval ${__SCRIPT}_popd
      
      unset CC FORCE_UNSAFE_CONFIGURE CFLAGS __STRIP __EXE_FILES __ARCH __TARGET __BIN_DIR
    done
    PATH="$__PATH"
    unset __PATH $(set | grep -o "^${__SCRIPT}_[^$= ]*" | xargs)
  done
popd
