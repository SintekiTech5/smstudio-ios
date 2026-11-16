#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_ROOT="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/smstudio-ios-dependencies"
VENDOR_DIR="$ROOT_DIR/ios/Vendor"
OPENSSL_COMMIT="c1eeb9406b6142148f267594197d853403d10208"
SRT_COMMIT="a8c6b65520f814c5bd8f801be48c33ceece7c4a6"

rm -rf "$BUILD_ROOT"
rm -rf \
  "$VENDOR_DIR/libsrt.xcframework" \
  "$VENDOR_DIR/libssl.xcframework" \
  "$VENDOR_DIR/libcrypto.xcframework" \
  "$VENDOR_DIR/include/srt" \
  "$VENDOR_DIR/licenses"
mkdir -p "$BUILD_ROOT" "$VENDOR_DIR"

git clone --quiet --depth 1 --branch openssl-3.5.4 \
  https://github.com/openssl/openssl.git "$BUILD_ROOT/openssl"
git clone --quiet --depth 1 --branch v1.5.4 \
  https://github.com/Haivision/srt.git "$BUILD_ROOT/srt"

test "$(git -C "$BUILD_ROOT/openssl" rev-parse HEAD)" = "$OPENSSL_COMMIT"
test "$(git -C "$BUILD_ROOT/srt" rev-parse HEAD)" = "$SRT_COMMIT"

JOBS="$(sysctl -n hw.ncpu)"

build_openssl() {
  local target="$1"
  local name="$2"
  local install_dir="$BUILD_ROOT/openssl-install/$name"
  local build_dir="$BUILD_ROOT/openssl-build/$name"

  mkdir -p "$build_dir" "$install_dir"
  (
    cd "$build_dir"
    "$BUILD_ROOT/openssl/Configure" "$target" no-shared no-tests \
      --prefix="$install_dir" \
      --openssldir="$install_dir/ssl"
    make -j"$JOBS"
    make install_sw
  )
}

build_srt() {
  local platform="$1"
  local architecture="$2"
  local sdk="$3"
  local openssl_dir="$4"
  local name="$platform-$architecture"
  local install_dir="$BUILD_ROOT/srt-install/$name"
  local build_dir="$BUILD_ROOT/srt-build/$name"

  cmake -S "$BUILD_ROOT/srt" -B "$build_dir" \
    -DCMAKE_SYSTEM_NAME=iOS \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_OSX_SYSROOT="$sdk" \
    -DCMAKE_OSX_ARCHITECTURES="$architecture" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0 \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$install_dir" \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DENABLE_APPS=OFF \
    -DENABLE_TESTING=OFF \
    -DENABLE_ENCRYPTION=ON \
    -DUSE_OPENSSL_PC=OFF \
    -DOPENSSL_ROOT_DIR="$openssl_dir" \
    -DOPENSSL_INCLUDE_DIR="$openssl_dir/include" \
    -DOPENSSL_SSL_LIBRARY="$openssl_dir/lib/libssl.a" \
    -DOPENSSL_CRYPTO_LIBRARY="$openssl_dir/lib/libcrypto.a" \
    -DOPENSSL_USE_STATIC_LIBS=TRUE
  cmake --build "$build_dir" --parallel "$JOBS"
  cmake --install "$build_dir"
  test -f "$install_dir/lib/libsrt.a"
}

build_openssl ios64-xcrun device-arm64
build_openssl iossimulator-arm64-xcrun simulator-arm64
build_openssl iossimulator-x86_64-xcrun simulator-x86_64

build_srt device arm64 iphoneos \
  "$BUILD_ROOT/openssl-install/device-arm64"
build_srt simulator arm64 iphonesimulator \
  "$BUILD_ROOT/openssl-install/simulator-arm64"
build_srt simulator x86_64 iphonesimulator \
  "$BUILD_ROOT/openssl-install/simulator-x86_64"

mkdir -p "$BUILD_ROOT/simulator-universal"
for library in libsrt.a libssl.a libcrypto.a; do
  case "$library" in
    libsrt.a)
      arm64_path="$BUILD_ROOT/srt-install/simulator-arm64/lib/$library"
      x86_64_path="$BUILD_ROOT/srt-install/simulator-x86_64/lib/$library"
      ;;
    *)
      arm64_path="$BUILD_ROOT/openssl-install/simulator-arm64/lib/$library"
      x86_64_path="$BUILD_ROOT/openssl-install/simulator-x86_64/lib/$library"
      ;;
  esac
  lipo -create "$arm64_path" "$x86_64_path" \
    -output "$BUILD_ROOT/simulator-universal/$library"
done

mkdir -p "$VENDOR_DIR/include" "$VENDOR_DIR/licenses"
cp -R "$BUILD_ROOT/srt-install/device-arm64/include/srt" "$VENDOR_DIR/include/"
cp "$BUILD_ROOT/openssl/LICENSE.txt" "$VENDOR_DIR/licenses/OpenSSL-LICENSE.txt"
cp "$BUILD_ROOT/srt/LICENSE" "$VENDOR_DIR/licenses/libsrt-LICENSE.txt"

xcodebuild -create-xcframework \
  -library "$BUILD_ROOT/srt-install/device-arm64/lib/libsrt.a" \
  -headers "$VENDOR_DIR/include" \
  -library "$BUILD_ROOT/simulator-universal/libsrt.a" \
  -headers "$VENDOR_DIR/include" \
  -output "$VENDOR_DIR/libsrt.xcframework"

for library in libssl.a libcrypto.a; do
  framework_name="${library%.a}.xcframework"
  xcodebuild -create-xcframework \
    -library "$BUILD_ROOT/openssl-install/device-arm64/lib/$library" \
    -headers "$BUILD_ROOT/openssl-install/device-arm64/include" \
    -library "$BUILD_ROOT/simulator-universal/$library" \
    -headers "$BUILD_ROOT/openssl-install/simulator-arm64/include" \
    -output "$VENDOR_DIR/$framework_name"
done

echo "Built encrypted libsrt and OpenSSL XCFrameworks for iOS device and simulator."
