SUMMARY = "Spektrum SBC OLED support"
DESCRIPTION = "Optional OLED status display service for Spektrum SBC devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r0"

inherit allarch systemd

SRC_URI += " \
    file://oled_status.py \
    file://spektrum-oled-status.service \
"

S = "${WORKDIR}"
SPEKTRUM_OLED_PYTHON_RDEPENDS ?= " \
    python3-core \
    python3-sqlite3 \
    python3-cbor2 \
    python3-pillow \
    python3-luma-oled \
"

SYSTEMD_SERVICE:${PN} = "spektrum-oled-status.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = " \
    spektrum-sbc-core \
    ${SPEKTRUM_OLED_PYTHON_RDEPENDS} \
"

do_install() {
    install -d ${D}/opt/spektrum/scripts/sbc
    install -d ${D}${systemd_system_unitdir}

    install -m 0644 ${WORKDIR}/oled_status.py ${D}/opt/spektrum/scripts/sbc/
    install -m 0644 ${WORKDIR}/spektrum-oled-status.service ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    /opt/spektrum/scripts/sbc/oled_status.py \
    ${systemd_system_unitdir}/spektrum-oled-status.service \
"
