#!/usr/bin/env bash
# Xcode's pre-build step: builds the app itself - the `roostr-ios` static
# library from the sibling RoostrWebsite repository's GPUI workspace - for the
# platform Xcode is building, and copies it to $DERIVED_FILE_DIR/rust, where
# the target links it from. Debug → cargo's dev profile (line tables only and
# no incremental cache, to keep the build small), Release → --release.
#
# Outside Xcode: PLATFORM_NAME=iphonesimulator CONFIGURATION=Debug \
#   DERIVED_FILE_DIR=/tmp/roostr-rust Scripts/build-rust.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
gpui="${ROOSTR_GPUI_DIR:-$root/../RoostrWebsite/gpui}"

case "${PLATFORM_NAME:?}" in
	iphonesimulator) target=aarch64-apple-ios-sim ;;
	iphoneos) target=aarch64-apple-ios ;;
	*) echo "error: unsupported platform $PLATFORM_NAME" >&2; exit 1 ;;
esac
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then
	profile=release
	flags=(--release)
else
	profile=debug
	flags=()
fi

# Xcode's environment targets the iOS SDK; build scripts compiled for this Mac
# (and the Odin engine build) must not inherit it.
env -i \
	HOME="$HOME" USER="${USER:-}" TMPDIR="${TMPDIR:-/tmp}" \
	PATH="$HOME/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
	IPHONEOS_DEPLOYMENT_TARGET="${IPHONEOS_DEPLOYMENT_TARGET:-17.0}" \
	CARGO_PROFILE_DEV_DEBUG=line-tables-only CARGO_INCREMENTAL=0 \
	${ODIN:+ODIN="$ODIN"} ${GLON_ODIN_DIR:+GLON_ODIN_DIR="$GLON_ODIN_DIR"} \
	${CARGO_TARGET_DIR:+CARGO_TARGET_DIR="$CARGO_TARGET_DIR"} \
	cargo build --manifest-path "$gpui/Cargo.toml" -p roostr-ios --lib --target "$target" ${flags[@]+"${flags[@]}"}

out="${DERIVED_FILE_DIR:?}/rust"
mkdir -p "$out"
cp -c "${CARGO_TARGET_DIR:-$gpui/target}/$target/$profile/libroostr_ios.a" "$out/libroostr_ios.a" 2>/dev/null \
	|| cp "${CARGO_TARGET_DIR:-$gpui/target}/$target/$profile/libroostr_ios.a" "$out/libroostr_ios.a"
