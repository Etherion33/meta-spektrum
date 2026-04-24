SUMMARY = "Spektrum SBC OLED support"
DESCRIPTION = "Optional OLED status display service for Spektrum SBC devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835c9145a2a186d828457ff340e82a8"
PR = "r0"

inherit allarch systemd

S = "${WORKDIR}"
SPEKTRUM_REPO_ROOT = "${THISDIR}/../../../../"
SPEKTRUM_SBC_DIR = "${SPEKTRUM_REPO_ROOT}/scripts/sbc"

SYSTEMD_SERVICE:${PN} = "spektrum-oled-status.service"
SYSTEMD_AUTO_ENABLE:${PN} = "disable"

RDEPENDS:${PN} = " \
    spektrum-sbc-core \
    python3-core \
    python3-json \
    python3-sqlite3 \
"

do_install() {
    install -d ${D}/opt/spektrum/scripts/sbc
    install -d ${D}${systemd_system_unitdir}

    install -m 0644 ${SPEKTRUM_SBC_DIR}/oled_status.py ${D}/opt/spektrum/scripts/sbc/
    install -m 0644 ${SPEKTRUM_SBC_DIR}/spektrum-oled-status.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    /opt/spektrum/scripts/sbc/oled_status.py \
    ${systemd_system_unitdir}/spektrum-oled-status.service \
"
