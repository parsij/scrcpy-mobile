#!/bin/bash

set -e

OUTPUT=$(cd $OUTPUT && pwd);
BUILD_DIR="$PWD/build/ffmpeg";
[[ -d "$BUILD_DIR" ]] || mkdir -pv "$BUILD_DIR";
cd "$BUILD_DIR" || exit;

# Clean and clone FFmpeg source code with specific tag
echo "Cleaning previous source..."
[[ -d "$BUILD_DIR/ffmpeg-source" ]] && rm -rf "$BUILD_DIR/ffmpeg-source"
[[ -d "$BUILD_DIR/ffmpeg-iphoneos-arm64" ]] && rm -rf "$BUILD_DIR/ffmpeg-iphoneos-arm64"
[[ -d "$BUILD_DIR/ffmpeg-iphonesimulator-arm64" ]] && rm -rf "$BUILD_DIR/ffmpeg-iphonesimulator-arm64"
[[ -d "$BUILD_DIR/ffmpeg-iphonesimulator-x86_64" ]] && rm -rf "$BUILD_DIR/ffmpeg-iphonesimulator-x86_64"

echo "Downloading FFmpeg source code..."
git clone --depth 1 --branch n8.1.1 https://github.com/FFmpeg/FFmpeg.git ffmpeg-source
cd ffmpeg-source || exit;

# Apply patch to h264_slice.c
# Force VideoToolbox HW accel even when the bitstream advertises colorspace=RGB
# (some Android encoders mis-report this and cause FFmpeg to skip VT and fall
#  back to software decoding, which is too slow on iPad for high-res streams).
echo "Applying patch to h264_slice.c..."
cat > h264_patch.diff << 'EOF'
--- a/libavcodec/h264_slice.c
+++ b/libavcodec/h264_slice.c
@@ -811,7 +811,7 @@ static enum AVPixelFormat get_pixel_format(H264Context *h, int force_callback)
         break;
     case 10:
 #if CONFIG_H264_VIDEOTOOLBOX_HWACCEL
-        if (h->avctx->colorspace != AVCOL_SPC_RGB)
+        // if (h->avctx->colorspace != AVCOL_SPC_RGB)
             *fmt++ = AV_PIX_FMT_VIDEOTOOLBOX;
 #endif
 #if CONFIG_H264_VULKAN_HWACCEL
@@ -873,7 +873,7 @@ static enum AVPixelFormat get_pixel_format(H264Context *h, int force_callback)
         *fmt++ = AV_PIX_FMT_CUDA;
 #endif
 #if CONFIG_H264_VIDEOTOOLBOX_HWACCEL
-        if (h->avctx->colorspace != AVCOL_SPC_RGB)
+        // if (h->avctx->colorspace != AVCOL_SPC_RGB)
             *fmt++ = AV_PIX_FMT_VIDEOTOOLBOX;
 #endif
EOF

patch -p1 < h264_patch.diff || echo "Patch failed, continuing..."

# Create libs directory structure
[[ -d "$OUTPUT" ]] || mkdir -pv "$OUTPUT"

# Function to build for a specific target
build_target() {
    local target=$1
    local arch=$2
    local sdk=$3
    local min_version=$4

    echo "Building FFmpeg for $target ($arch)..."

    # Create separate source directory for each target to avoid conflicts
    target_source_dir="$BUILD_DIR/ffmpeg-$target"
    cp -r "$BUILD_DIR/ffmpeg-source" "$target_source_dir"
    cd "$target_source_dir" || exit

    # Create target-specific build directory
    build_dir="$BUILD_DIR/$target"
    mkdir -pv "$build_dir"

    # Clean any previous build artifacts
    make distclean 2>/dev/null || true

    # Configure for target
    ./configure \
        --enable-cross-compile \
        --disable-debug \
        --disable-doc \
        --enable-pic \
        --disable-audiotoolbox \
        --disable-sdl2 \
        --disable-libxcb \
        --target-os=darwin \
        --arch=$arch \
        --cc="xcrun -sdk $sdk clang" \
        --as="gas-preprocessor.pl -arch $arch -- xcrun -sdk $sdk clang" \
        --extra-cflags="-arch $arch -m${sdk%-*}-version-min=$min_version" \
        --extra-ldflags="-arch $arch -m${sdk%-*}-version-min=$min_version" \
        --prefix="$build_dir"

    # Build
    make -j8
    make install

    # Create target-specific libs directory with platform/arch structure
    platform_dir="$OUTPUT/$sdk"
    target_lib_dir="$platform_dir/$arch"
    mkdir -pv "$target_lib_dir"

    # Copy built libraries
    find "$build_dir/lib" -name "*.a" -exec cp -v {} "$target_lib_dir/" \;

    # Copy headers (only once)
    cp -rv "$build_dir/include" "$OUTPUT/"

    # Return to main build directory
    cd "$BUILD_DIR" || exit
}

# Build for different targets
build_target "iphoneos-arm64" "arm64" "iphoneos" "13.0"
build_target "iphonesimulator-arm64" "arm64" "iphonesimulator" "13.0"
build_target "iphonesimulator-x86_64" "x86_64" "iphonesimulator" "13.0"

echo "FFmpeg build completed!"
echo "Libraries are available in: $OUTPUT"
echo "Built targets:"
echo "  - iphoneos/arm64"
echo "  - iphonesimulator/arm64"
echo "  - iphonesimulator/x86_64"
