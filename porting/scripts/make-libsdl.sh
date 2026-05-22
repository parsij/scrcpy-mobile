#!/bin/bash
# Build SDL3 3.4.8 as a static library for three iOS ABIs via CMake +
# ios.toolchain.cmake. The previous SDL2 script drove xcodebuild against
# SDL's bundled Xcode project; SDL3 only ships a framework target there, so
# the project no longer has a "Static Library-iOS" scheme and we have to use
# the CMake path.
#
# OUTPUT comes in from the porting Makefile.

set -e;
set -x;

SDL_TAG=release-3.4.8
DEPLOYMENT_TARGET=13.0

OUTPUT=$(cd "$OUTPUT" && pwd);
TOOLCHAIN="$(cd "$(dirname "$0")/.." && pwd)/../ios-cmake/ios.toolchain.cmake"
BUILD_DIR="$PWD/build/libsdl";
mkdir -p "$BUILD_DIR";
cd "$BUILD_DIR";

# Fetch a clean source tree per build.
rm -rf SDL-source
git clone --depth 1 --branch "$SDL_TAG" https://github.com/libsdl-org/SDL.git SDL-source

# Disable the iOS UITouchTypeIndirectPointer recognizer path so SDL falls
# back to plain touch handling — same intent as the original SDL2 patch,
# the constant still exists in SDL3 at the same site (src/video/uikit/
# SDL_uikitview.m around line 109).
sdl_uikitview=$(ls SDL-source/src/video/uikit/SDL_uikitview.m)
sed -e 's/UITouchTypeIndirectPointer/UITouchTypeIndirectPointer+1000/g' \
    "$sdl_uikitview" > "$sdl_uikitview.replaced"
mv -v "$sdl_uikitview.replaced" "$sdl_uikitview"

# NOTE: dropped two SDL2-era patches that no longer apply:
#  - SDL_UpdateCommandGeneration injection in SDL_render.c — SDL3 already
#    bumps render_command_generation internally in FlushRenderCommands().
#  - ENABLE_GCKEYBOARD / ENABLE_GCMOUSE macro sed — those macros are gone in
#    SDL3 (Game Controller integration is function-based now); if these end
#    up interfering with touch we'll add an SDL_SetHint call from the app.

build_target() {
    local platform=$1   # OS64 | SIMULATORARM64 | SIMULATOR64
    local arch=$2       # arm64 | x86_64
    local sdk=$3        # iphoneos | iphonesimulator

    local target_build="$BUILD_DIR/build-$platform"
    local install_dir="$BUILD_DIR/install-$platform"

    echo "=> Building SDL3 for $platform / $arch ($sdk)..";

    rm -rf "$target_build" "$install_dir"
    mkdir -p "$target_build"
    cd "$target_build"

    cmake -G "Unix Makefiles" \
        -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
        -DPLATFORM="$platform" \
        -DDEPLOYMENT_TARGET="$DEPLOYMENT_TARGET" \
        -DARCHS="$arch" \
        -DENABLE_BITCODE=OFF \
        -DSDL_SHARED=OFF \
        -DSDL_STATIC=ON \
        -DSDL_TEST_LIBRARY=OFF \
        -DSDL_TESTS=OFF \
        -DSDL_EXAMPLES=OFF \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$install_dir" \
        -DCMAKE_C_FLAGS="-DCFRunLoopRunInMode=CFRunLoopRunInMode_fix" \
        ../SDL-source

    cmake --build . --config Release -j8
    cmake --install .

    # Place the static lib in the same per-ABI layout as the rest of porting/libs.
    local out_lib_dir="$OUTPUT/$sdk/$arch"
    mkdir -p "$out_lib_dir"
    cp -v "$install_dir/lib/libSDL3.a" "$out_lib_dir/"

    # Headers (only need to copy once; all ABIs share the same API).
    mkdir -p "$OUTPUT/include"
    rm -rf "$OUTPUT/include/SDL3"
    cp -rv "$install_dir/include/SDL3" "$OUTPUT/include/"

    # On the OS64 (real-device arm64) pass, also stage a pkg-config file so
    # scrcpy's host meson setup can satisfy its dependency('sdl3', ...) check
    # purely against our staged tree. The pkg-config file's prefix is rewritten
    # to point at $OUTPUT so it is location-independent.
    if [ "$platform" = "OS64" ]; then
        mkdir -p "$OUTPUT/lib/pkgconfig"
        sed "s|^prefix=.*|prefix=$OUTPUT|" \
            "$install_dir/lib/pkgconfig/sdl3.pc" \
            > "$OUTPUT/lib/pkgconfig/sdl3.pc"
        # The .a we want pkg-config to advertise lives under iphoneos/arm64,
        # not the default lib/. Override libdir for that.
        sed -i.bak "s|^libdir=.*|libdir=$OUTPUT/iphoneos/arm64|" \
            "$OUTPUT/lib/pkgconfig/sdl3.pc"
        rm -f "$OUTPUT/lib/pkgconfig/sdl3.pc.bak"
    fi

    cd "$BUILD_DIR"
}

build_target OS64           arm64  iphoneos
build_target SIMULATORARM64 arm64  iphonesimulator
build_target SIMULATOR64    x86_64 iphonesimulator

echo "SDL3 build completed!"
ls -la "$OUTPUT"/iphoneos/arm64/libSDL3.a \
       "$OUTPUT"/iphonesimulator/arm64/libSDL3.a \
       "$OUTPUT"/iphonesimulator/x86_64/libSDL3.a
