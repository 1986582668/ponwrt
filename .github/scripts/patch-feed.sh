#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Apply the AN7583 GPON patches to the pon_drivers feed of an OpenWrt tree.
#
#   usage: .github/scripts/patch-feed.sh <buildroot> [feed-dir-name]
#
# The feed is cloned by ./scripts/feeds update, so it must be patched after
# that step and before make runs. The script is idempotent: a patch that is
# already applied is reported and skipped.
#
# Every patch is verified right here, and any failure aborts the run. A feed
# that moved upstream must break the build rather than ship a firmware whose
# xpon driver still answers -EOPNOTSUPP for GPON.

set -eu

ROOT="${1:?usage: patch-feed.sh <buildroot> [feed-dir]}"
FEED="${2:-pon_drivers}"
FEED_SRC="$ROOT/feeds/$FEED"
HERE=$(cd "$(dirname "$0")" && pwd)
PATCH_DIR="$HERE/../patches"
XPON="$FEED_SRC/airoha-xpon/src"

[ -d "$XPON" ] || {
	echo "error: $XPON not found; run ./scripts/feeds update -a first" >&2
	exit 1
}

apply_one() {
	patch_file="$1"
	name=$(basename "$patch_file")

	if git -C "$FEED_SRC" apply --check -p1 "$patch_file" 2>/dev/null; then
		git -C "$FEED_SRC" apply -p1 "$patch_file"
		echo "applied         $name"
		return 0
	fi

	if git -C "$FEED_SRC" apply --reverse --check -p1 "$patch_file" \
			2>/dev/null; then
		echo "already applied $name"
		return 0
	fi

	# A non-git feed checkout cannot be handled with git apply.
	if patch -p1 -N --dry-run -d "$FEED_SRC" -i "$patch_file" \
			>/dev/null 2>&1; then
		patch -p1 -N -d "$FEED_SRC" -i "$patch_file"
		echo "applied         $name (patch)"
		return 0
	fi

	echo "error: cannot apply $name cleanly" >&2
	git -C "$FEED_SRC" apply --check -p1 "$patch_file" || true
	exit 1
}

for patch_file in "$PATCH_DIR"/*.patch; do
	[ -f "$patch_file" ] || continue
	apply_one "$patch_file"
done

# ---------------------------------------------------------------- assertions

check() {
	description="$1"
	shift
	if "$@"; then
		echo "ok              $description"
	else
		echo "error: $description" >&2
		exit 1
	fi
}

check "PCS profile mapping is used for the line mode" \
	grep -q 'airoha_xpon_mode_to_pcs_profile(xpon->active_mode)' \
	"$XPON/airoha-xpon-xgpon.c"

check "the XG-PON-only PCS ternary is gone" \
	test "$(grep -c 'AIROHA_PCS_PON_MODE_XGPON' "$XPON/airoha-xpon-xgpon.c")" = 0

check "the GPON mode entry is mac_supported" \
	test "$(grep -A7 'AIROHA_XPON_MODE_GPON,' "$XPON/airoha-xpon-mode.c" |
		grep -c 'mac_supported')" = 1

check "all six line modes are mac_supported" \
	test "$(grep -c 'mac_supported = true' "$XPON/airoha-xpon-mode.c")" = 6

check "the RX mode diagnostic override is present" \
	grep -q 'module_param(rx_mode_override' "$XPON/airoha-xpon-xgpon.c"

echo "GPON patches verified in $FEED_SRC"
