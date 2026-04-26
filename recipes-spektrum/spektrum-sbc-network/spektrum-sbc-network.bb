SUMMARY = "Spektrum SBC networking helpers"
DESCRIPTION = "AP and station-mode network helper scripts for Spektrum SBC devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r12"

inherit allarch

SRC_URI += " \
    file://setup_hotspot.sh \
    file://switch_to_sta.sh \
"

S = "${WORKDIR}"

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
    install -m 0755 ${WORKDIR}/setup_hotspot.sh ${D}/opt/spektrum/scripts/sbc/
    install -m 0755 ${WORKDIR}/switch_to_sta.sh ${D}/opt/spektrum/scripts/sbc/
}

FILES:${PN} += " \
    /opt/spektrum/scripts/sbc/setup_hotspot.sh \
    /opt/spektrum/scripts/sbc/switch_to_sta.sh \
"
