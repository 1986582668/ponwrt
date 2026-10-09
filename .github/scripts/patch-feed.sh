#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-only
#
# Apply the local patches to a feed of an OpenWrt tree.
#
#   usage: .github/scripts/patch-feed.sh <buildroot> [feed-dir-name]
#
# The feeds are cloned by ./scripts/feeds update, so they must be patched after
# that step and before make runs. The script is idempotent: a patch that is
# already applied is reported and skipped.
#
# Patches live in .github/patches/<feed>/ when they belong to one specific
# feed, and in .github/patches/ when they are shared by all of them. This
# script is called once per feed:
#
#   sh .github/scripts/patch-feed.sh "$PWD" pon_drivers
#   sh .github/scripts/patch-feed.sh "$PWD" pon_userspace
#
# Every patch is verified right here, and any failure aborts the run. A feed
# that moved upstream must break the build rather than ship a firmware whose
# xpon driver still answers -EOPNOTSUPP for GPON, or whose PON page offers no
# way to select the line mode the build enables.

set -eu

ROOT="${1:?usage: patch-feed.sh <buildroot> [feed-dir]}"
FEED="${2:-pon_drivers}"
FEED_SRC="$ROOT/feeds/$FEED"
HERE=$(cd "$(dirname "$0")" && pwd)

[ -d "$FEED_SRC" ] || {
	echo "error: $FEED_SRC not found; run ./scripts/feeds update -a first" >&2
	exit 1
}

PATCH_DIR="$HERE/../patches/$FEED"
[ -d "$PATCH_DIR" ] || PATCH_DIR="$HERE/../patches"

# Fail early when a feed directory exists but carries no patches at all: that
# would mean the feed name in the workflow drifts away from the tree layout.
if ! ls "$PATCH_DIR"/*.patch >/dev/null 2>&1; then
	echo "error: no patches found in $PATCH_DIR" >&2
	exit 1
fi

apply_one() {
	patch_file="$1"
	name=$(basename "$patch_file")

	if git -C "$FEED_SRC" apply --check -p1 "$patch_file" 2>/dev/null; then
		git -C "$FEED_SRC" apply -p1 "$patch_file"
		echo "applied         $FEED/$name"
		return 0
	fi

	if git -C "$FEED_SRC" apply --reverse --check -p1 "$patch_file" \
			2>/dev/null; then
		echo "already applied $FEED/$name"
		return 0
	fi

	# A non-git feed checkout cannot be handled with git apply.
	if patch -p1 -N --dry-run -d "$FEED_SRC" -i "$patch_file" \
			>/dev/null 2>&1; then
		patch -p1 -N -d "$FEED_SRC" -i "$patch_file"
		echo "applied         $FEED/$name (patch)"
		return 0
	fi

	echo "error: cannot apply $FEED/$name cleanly" >&2
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

case "$FEED" in
pon_drivers)
	XPON="$FEED_SRC/airoha-xpon/src"

	[ -d "$XPON" ] || {
		echo "error: $XPON not found" >&2
		exit 1
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

	# This one is the *binary* fingerprint, so it must live in an allocated
	# section. MODULE_PARM_DESC text ends up in .modinfo, which the OpenWrt
	# scripts/strip-kmod.sh step ("objcopy -x -G __this_module --strip-unneeded")
	# drops from the packaged module. A format string reachable from code lands in
	# .rodata instead and survives stripping. Neither phrase exists upstream.
	check "the RX mode diagnostic log string is present" \
		grep -q 'digital RX mode readback' "$XPON/airoha-xpon-xgpon.c"
	;;
pon_userspace)
	LUCI="$FEED_SRC/luci-app-pon/htdocs/luci-static/resources/view/pon"

	[ -f "$LUCI/config.js" ] || {
		echo "error: $LUCI/config.js not found" >&2
		exit 1
	}

	# The driver takes six line modes; a build that enables GPON in the kernel
	# but not in this list ships a mode nobody can select. The other two
	# ListValues on this page (OMCC version, OAM profile) use the same
	# o.value() call, so each entry is named explicitly instead of counted.
	for entry in "o.value('', _('Driver default'))" \
		     "o.value('gpon', _('GPON'))" \
		     "o.value('xgpon', _('XG-PON'))" \
		     "o.value('xgspon', _('XGS-PON'))" \
		     "o.value('epon-10g-1g', _('10G-EPON 10G/1G'))" \
		     "o.value('epon-10g-10g', _('10G-EPON 10G/10G'))"; do
		check "the PON page offers $entry" \
			grep -qF "$entry" "$LUCI/config.js"
	done

	# GPON carries the same PLOAM identity as XG-PON: serial number and
	# registration id both have to stay visible for it.
	check "GPON keeps the PLOAM identity fields" \
		test "$(grep -c "o.depends('mode', 'gpon')" "$LUCI/config.js")" = 2
	check "the line mode list has no stale entry" \
		test "$(grep -c "o.value('epon-1g'" "$LUCI/config.js")" = 0
	;;
*)
	echo "error: no assertions defined for feed '$FEED'" >&2
	exit 1
	;;
esac

echo "$FEED patches verified in $FEED_SRC"
