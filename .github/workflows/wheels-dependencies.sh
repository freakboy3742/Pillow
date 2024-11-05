#!/bin/bash

# Safety check - Pillow builds require that CIBW_ARCHS is set, and that it only
# contains a single value (even though cibuildwheel allows multiple values in
# CIBW_ARCHS).
if [[ -z "$CIBW_ARCHS" ]]; then
    echo "ERROR: Pillow builds require CIBW_ARCHS be defined."
    exit 1
fi
if [[ "$CIBW_ARCHS" == *" "* ]]; then
    echo "ERROR: Pillow builds only support a single architecture in CIBW_ARCHS."
    exit 1
fi
PLAT=$CIBW_ARCHS

# Setup that needs to be done before multibuild utils are invoked. Process
# potential cross-build platforms before native platforms to ensure that we pick
# up the cross environment.
PROJECTDIR=$(pwd)
if [[ "$CIBW_PLATFORM" == "ios" ]]; then
    echo "ERROR: Pillow can't build the combined iOS platform; run separate iphoneos and iphonesimulator builds."
    exit 1
elif [[ "$CIBW_PLATFORM" == "iphoneos" || "$CIBW_PLATFORM" == "iphonesimulator" ]]; then
    IOS_SDK=$CIBW_PLATFORM

    # Build iOS builds in `build/iphoneos` or `build/iphonesimulator/`
    # (depending on the build target). Install them into `build/deps/iphoneos`
    # or `build/deps/iphonesimulator`
    WORKDIR=$(pwd)/build/$IOS_SDK
    BUILD_PREFIX=$(pwd)/build/deps/$IOS_SDK
    PATCH_DIR=$(pwd)/patches/iOS

    # GNU tooling insists on using aarch64 rather than arm64
    if [[ $PLAT == "arm64" ]]; then
        GNU_ARCH=aarch64
    else
        GNU_ARCH=x86_64
    fi

    IOS_SDK_PATH=$(xcrun --sdk $IOS_SDK --show-sdk-path)
    if [[ "$IOS_SDK" == "iphonesimulator" ]]; then
        CMAKE_SYSTEM_NAME=iOS
        IOS_HOST_TRIPLE=$PLAT-apple-ios$IPHONEOS_DEPLOYMENT_TARGET-simulator
    else
        CMAKE_SYSTEM_NAME=iOS
        IOS_HOST_TRIPLE=$PLAT-apple-ios$IPHONEOS_DEPLOYMENT_TARGET
    fi

    # GNU Autotools doesn't recognize the existence of arm64-apple-ios-simulator
    # as a valid host. However, the only difference between arm64-apple-ios and
    # arm64-apple-ios-simulator is the choice of sysroot, and that is
    # coordinated by CC,CFLAGS etc. From the perspective of configure, the two
    # platforms are identical, so we can use arm64-apple-ios consistently.
    # This (mostly) avoids us needing to patch config.sub in dependency sources.
    HOST_CONFIGURE_FLAGS="--disable-shared --enable-static --host=$PLAT-apple-ios$IPHONEOS_DEPLOYMENT_TARGET --build=$PLAT-apple-darwin"

    # Cmake has native support for iOS. However, most of that support is based
    # on using the Xcode builder, which isn't very helpful for most of Pillow's
    # dependencies. Therefore, we lean on the OSX configurations, plus CC/CFLAGS
    # etc to ensure the right sysroot is selected.
    HOST_CMAKE_FLAGS="-DCMAKE_SYSTEM_NAME=$CMAKE_SYSTEM_NAME -DCMAKE_SYSTEM_PROCESSOR=$GNU_ARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET -DCMAKE_OSX_SYSROOT=$IOS_SDK_PATH -DBUILD_SHARED_LIBS=NO"

    # Meson needs to be pointed at a cross-platform configuration file
    # This will be generated once CC etc have been evaluated.
    HOST_MESON_FLAGS="--cross-file $WORKDIR/meson-cross.txt -Dprefer_static=true -Ddefault_library=static"

elif [[ "$(uname -s)" == "Darwin" ]]; then
    # Build macOS dependencies in `build/darwin`
    # Install them into `build/deps/darwin`
    WORKDIR=$(pwd)/build/darwin
    BUILD_PREFIX=$(pwd)/build/deps/darwin
else
    # Build prefix will default to /usr/local
    WORKDIR=$(pwd)/build
    MB_ML_LIBC=${AUDITWHEEL_POLICY::9}
    MB_ML_VER=${AUDITWHEEL_POLICY:9}
fi

# Define custom utilities
source wheels/multibuild/common_utils.sh
source wheels/multibuild/library_builders.sh
if [ -z "$IS_MACOS" ]; then
    source wheels/multibuild/manylinux_utils.sh
fi

ARCHIVE_SDIR=pillow-depends-main

# Package versions for fresh source builds
FREETYPE_VERSION=2.13.3
HARFBUZZ_VERSION=10.1.0
LIBPNG_VERSION=1.6.44
JPEGTURBO_VERSION=3.1.0
OPENJPEG_VERSION=2.5.3
XZ_VERSION=5.6.3
TIFF_VERSION=4.6.0
LCMS2_VERSION=2.16
ZLIB_NG_VERSION=2.2.3
LIBWEBP_VERSION=1.5.0
BZIP2_VERSION=1.0.8
LIBXCB_VERSION=1.17.0
BROTLI_VERSION=1.1.0

function build_pkg_config {
    if [ -e pkg-config-stamp ]; then return; fi
    # This essentially duplicates the Homebrew recipe.
    # The SDK path is *always* macOS, because we need a binary that can be
    # executed on the build machine; but we can create a host-specific pc-path
    # to store iOS .pc files. To ensure a macOS-compatible build, we temporarily
    # clear environment flags that set iOS-specific values.
    ORIGINAL_CFLAGS=$CFLAGS
    ORIGINAL_CPPFLAGS=$CPPFLAGS
    if [ -n "$IOS_SDK" ]; then
        ORIGINAL_HOST_CONFIGURE_FLAGS=$HOST_CONFIGURE_FLAGS
        ORIGINAL_IPHONEOS_DEPLOYMENT_TARGET=$IPHONEOS_DEPLOYMENT_TARGET
    fi

    CFLAGS="$CFLAGS -Wno-int-conversion"
    CPPFLAGS=""
    unset HOST_CONFIGURE_FLAGS
    unset IPHONEOS_DEPLOYMENT_TARGET

    build_simple pkg-config 0.29.2 https://pkg-config.freedesktop.org/releases tar.gz \
        --disable-debug --disable-host-tool --with-internal-glib \
        --with-pc-path=$BUILD_PREFIX/share/pkgconfig:$BUILD_PREFIX/lib/pkgconfig \
        --with-system-include-path=$(xcrun --show-sdk-path --sdk macosx)/usr/include

    CFLAGS=$ORIGINAL_CFLAGS
    CPPFLAGS=$ORIGINAL_CPPFLAGS
    if [ -n "$IOS_SDK" ]; then
        HOST_CONFIGURE_FLAGS=$ORIGINAL_HOST_CONFIGURE_FLAGS
        IPHONEOS_DEPLOYMENT_TARGET=$ORIGINAL_IPHONEOS_DEPLOYMENT_TARGET
    fi;

    PKG_CONFIG=$BUILD_PREFIX/bin/pkg-config
    touch pkg-config-stamp
}

function build_zlib_ng {
    if [ -e zlib-stamp ]; then return; fi
    fetch_unpack https://github.com/zlib-ng/zlib-ng/archive/$ZLIB_NG_VERSION.tar.gz zlib-ng-$ZLIB_NG_VERSION.tar.gz
    (cd zlib-ng-$ZLIB_NG_VERSION \
        && ./configure --prefix=$BUILD_PREFIX --zlib-compat \
        && make -j4 \
        && make install)

    if [ -n "$IS_MACOS" ] && [ -z "$IOS_SDK" ]; then
        # Ensure that on macOS, the library name is an absolute path, not an
        # @rpath, so that delocate picks up the right library (and doesn't need
        # DYLD_LIBRARY_PATH to be set). The default Makefile doesn't have an
        # option to control the install_name. iOS only builds the static library,
        # so there's no need to do anything.
        install_name_tool -id $BUILD_PREFIX/lib/libz.1.dylib $BUILD_PREFIX/lib/libz.1.dylib
    fi

    touch zlib-stamp
}

function build_brotli {
    if [ -e brotli-stamp ]; then return; fi
    local name=brotli
    local version=$BROTLI_VERSION
    local out_dir=$(fetch_unpack https://github.com/google/brotli/archive/v$BROTLI_VERSION.tar.gz brotli-$BROTLI_VERSION.tar.gz)
    (cd $out_dir \
        && cmake -DCMAKE_INSTALL_PREFIX=$BUILD_PREFIX -DCMAKE_INSTALL_LIBDIR=$BUILD_PREFIX/lib -DCMAKE_INSTALL_NAME_DIR=$BUILD_PREFIX/lib $HOST_CMAKE_FLAGS  . \
        && make install)
    touch brotli-stamp
}

function build_harfbuzz {
    if [ -e harfbuzz-stamp ]; then return; fi
    local name=harfbuzz
    local version=$HARFBUZZ_VERSION

    python3 -m pip install --disable-pip-version-check meson ninja

    local out_dir=$(fetch_unpack https://github.com/harfbuzz/harfbuzz/releases/download/$HARFBUZZ_VERSION/harfbuzz-$HARFBUZZ_VERSION.tar.xz harfbuzz-$HARFBUZZ_VERSION.tar.xz)
    (cd $out_dir \
        && meson setup build --prefix=$BUILD_PREFIX --libdir=$BUILD_PREFIX/lib --buildtype=release -Dfreetype=enabled -Dglib=disabled $HOST_MESON_FLAGS)
    (cd $out_dir/build \
        && meson install)
    touch harfbuzz-stamp
}

function build {
    build_xz

    if [ -z "$IS_ALPINE" ] && [ -z "$SANITIZER" ] && [ -z "$IS_MACOS" ]; then
        yum remove -y zlib-devel
    fi
    build_zlib_ng

    build_simple xcb-proto 1.17.0 https://xorg.freedesktop.org/archive/individual/proto
    if [ -n "$IS_MACOS" ]; then
        build_simple xorgproto 2024.1 https://www.x.org/pub/individual/proto
        build_simple libXau 1.0.12 https://www.x.org/pub/individual/lib
        build_simple libpthread-stubs 0.5 https://xcb.freedesktop.org/dist
    else
        sed s/\${pc_sysrootdir\}// $BUILD_PREFIX/share/pkgconfig/xcb-proto.pc > $BUILD_PREFIX/lib/pkgconfig/xcb-proto.pc
    fi
    build_simple libxcb $LIBXCB_VERSION https://www.x.org/releases/individual/lib

    build_libjpeg_turbo

    if [ -n "$IS_MACOS" ]; then
        # Custom tiff build to include jpeg; by default, configure won't include
        # headers/libs in the custom macOS/iOS prefix. Explicitly disable webp,
        # libdeflate and zstd, because on x86_64 macs, it will pick up the
        # Homebrew versions of those libraries from /usr/local.
        build_simple tiff $TIFF_VERSION https://download.osgeo.org/libtiff tar.gz \
            --with-jpeg-include-dir=$BUILD_PREFIX/include --with-jpeg-lib-dir=$BUILD_PREFIX/lib \
            --disable-webp --disable-libdeflate --disable-zstd
    else
        build_tiff
    fi

    build_libpng
    build_lcms2
    build_openjpeg

    ORIGINAL_CFLAGS=$CFLAGS
    CFLAGS="$CFLAGS -O3 -DNDEBUG"
    if [ -n "$IS_MACOS" ]; then
        CFLAGS="$CFLAGS -Wl,-headerpad_max_install_names"
    fi
    build_simple libwebp $LIBWEBP_VERSION \
        https://storage.googleapis.com/downloads.webmproject.org/releases/webp tar.gz \
        --enable-libwebpmux --enable-libwebpdemux
    CFLAGS=$ORIGINAL_CFLAGS

    build_brotli

    if [ -n "$IS_MACOS" ]; then
        # Custom freetype build
        build_simple freetype $FREETYPE_VERSION https://download.savannah.gnu.org/releases/freetype tar.gz --with-harfbuzz=no
    else
        build_freetype
    fi

    if [ -z "$IOS_SDK" ]; then
        # On iOS, there's no vendor-provided raqm, and we can't ship it due to
        # licensing, so there's no point building harfbuzz.
        build_harfbuzz
    fi
}

function create_meson_cross_config {
    cat << EOF > $WORKDIR/meson-cross.txt
[binaries]
pkg-config = '$BUILD_PREFIX/bin/pkg-config'
cmake = '$(which cmake)'
c = '$CC'
cpp = '$CXX'
strip = '$STRIP'

[built-in options]
c_args = '$CFLAGS -I$BUILD_PREFIX/include'
cpp_args = '$CXXFLAGS -I$BUILD_PREFIX/include'
c_link_args = '$CFLAGS -L$BUILD_PREFIX/lib'
cpp_link_args = '$CFLAGS -L$BUILD_PREFIX/lib'

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = '$(uname -m)'
cpu = '$(uname -m)'
endian = 'little'

EOF
}

# Perform all dependency builds in the working directory.
mkdir -p $WORKDIR
pushd $WORKDIR > /dev/null

# Any stuff that you need to do before you start building the wheels
# Runs in the root directory of this repository.
if [[ ! -d $WORKDIR/pillow-depends-main ]]; then
  if [[ ! -f $PROJECTDIR/pillow-depends-main.zip ]]; then
    echo "Download pillow dependency sources..."
    curl -fSL -o $PROJECTDIR/pillow-depends-main.zip https://github.com/python-pillow/pillow-depends/archive/main.zip
  fi

  echo "Unpacking pillow dependency sources..."
  untar $PROJECTDIR/pillow-depends-main.zip
fi

if [[ -n "$IS_MACOS" ]]; then
    # Ensure the basic structure of the build prefix directory exists.
    mkdir -p "$BUILD_PREFIX/bin"
    mkdir -p "$BUILD_PREFIX/lib"

    # Ensure pkg-config is available. This is done *before* setting CC, CFLAGS
    # etc to ensure that the build is *always* a macOS build, even when building
    # for iOS.
    build_pkg_config

    # Ensure cmake is available, and that the default prefix used by CMake is
    # the build prefix
    python3 -m pip install --disable-pip-version-check cmake
    export CMAKE_PREFIX_PATH=$BUILD_PREFIX

    if [[ -n "$IOS_SDK" ]]; then
        export AR="$(xcrun --find --sdk $IOS_SDK ar)"
        export CPP="$(xcrun --find --sdk $IOS_SDK clang) -E"
        export CC=$(xcrun --find --sdk $IOS_SDK clang)
        export CXX=$(xcrun --find --sdk $IOS_SDK clang++)
        export LD=$(xcrun --find --sdk $IOS_SDK ld)
        export STRIP=$(xcrun --find --sdk $IOS_SDK strip)

        CPPFLAGS="$CPPFLAGS --sysroot=$IOS_SDK_PATH"
        CFLAGS="-target $IOS_HOST_TRIPLE --sysroot=$IOS_SDK_PATH -mios-version-min=$IPHONEOS_DEPLOYMENT_TARGET"
        CXXFLAGS="-target $IOS_HOST_TRIPLE --sysroot=$IOS_SDK_PATH -mios-version-min=$IPHONEOS_DEPLOYMENT_TARGET"

        # Having IPHONEOS_DEPLOYMENT_TARGET in the environment causes problems
        # with some cross-building toolchains, because it introduces implicit
        # behavior into clang.
        unset IPHONEOS_DEPLOYMENT_TARGET

        # Now that we know CC etc, we can create a meson cross-configuration file
        create_meson_cross_config
    fi
fi

wrap_wheel_builder build

# Return to the project root to finish the build
popd > /dev/null

# Append licenses
for filename in wheels/dependency_licenses/*; do
  echo -e "\n\n----\n\n$(basename $filename | cut -f 1 -d '.')\n" | cat >> LICENSE
  cat $filename >> LICENSE
done
