SUMMARY = "Spektrum SBC networking helpers"
DESCRIPTION = "AP and station-mode network helper scripts for Spektrum SBC devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835c9145a2a186d828457ff340e82a8"
PR = "r0"

inherit allarch

S = "${WORKDIR}"
SPEKTRUM_REPO_ROOT = "${THISDIR}/../../../../"
SPEKTRUM_SBC_DIR = "${SPEKTRUM_REPO_ROOT}/scripts/sbc"

RDEPENDS:${PN} = " \
    bash \
    coreutils \
    curl \
    dnsmasq \
    hostapd \
    iproute2 \
    networkmanager \
"

do_install() {
    install -d ${D}/opt/spektrum/scripts/sbc
    install -m 0755 ${SPEKTRUM_SBC_DIR}/setup_hotspot.sh ${D}/opt/spektrum/scripts/sbc/
    install -m 0755 ${SPEKTRUM_SBC_DIR}/switch_to_sta.sh ${D}/opt/spektrum/scripts/sbc/
}

FILES:${PN} += " \
    /opt/spektrum/scripts/sbc/setup_hotspot.sh \
    /opt/spektrum/scripts/sbc/switch_to_sta.sh \
"
