SUMMARY = "Spektrum SBC meta package"
DESCRIPTION = "Selectable Spektrum SBC feature set for Yocto images"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835c9145a2a186d828457ff340e82a8"
PR = "r1"

inherit allarch

ALLOW_EMPTY:${PN} = "1"
PACKAGECONFIG ??= "network streaming"

RDEPENDS:${PN} = " \
    spektrum-sbc-core \
    ${@bb.utils.contains('PACKAGECONFIG', 'network', 'spektrum-sbc-network', '', d)} \
    ${@bb.utils.contains('PACKAGECONFIG', 'streaming', 'spektrum-sbc-streaming', '', d)} \
    ${@bb.utils.contains('PACKAGECONFIG', 'oled', 'spektrum-sbc-oled', '', d)} \
    ${@bb.utils.contains('PACKAGECONFIG', 'tailscale', 'spektrum-sbc-tailscale', '', d)} \
"
