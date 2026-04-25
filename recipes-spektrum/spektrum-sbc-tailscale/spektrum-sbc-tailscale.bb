SUMMARY = "Spektrum SBC Tailscale integration"
DESCRIPTION = "Optional enrollment glue for a tailscale package provided by another Yocto layer"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r0"

inherit allarch systemd

SRC_URI += " \
    file://tailscale_enroll.sh \
    file://spektrum-tailscale-enroll.service \
    file://spektrum-tailscale-enroll.path \
"

S = "${WORKDIR}"

SYSTEMD_SERVICE:${PN} = "spektrum-tailscale-enroll.service spektrum-tailscale-enroll.path"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = " \
    spektrum-sbc-core \
    bash \
    tailscale \
"

do_install() {
    install -d ${D}/opt/spektrum/scripts/sbc
    install -d ${D}${systemd_system_unitdir}

    install -m 0755 ${WORKDIR}/tailscale_enroll.sh ${D}/opt/spektrum/scripts/sbc/
    install -m 0644 ${WORKDIR}/spektrum-tailscale-enroll.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/spektrum-tailscale-enroll.path ${D}${systemd_system_unitdir}/
}

FILES:${PN} += " \
    /opt/spektrum/scripts/sbc/tailscale_enroll.sh \
    ${systemd_system_unitdir}/spektrum-tailscale-enroll.service \
    ${systemd_system_unitdir}/spektrum-tailscale-enroll.path \
"
