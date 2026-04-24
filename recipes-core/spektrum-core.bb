SUMMARY = "Spektrum SBC core runtime"
DESCRIPTION = "Core provisioning, state handling, and systemd runtime for Spektrum SBC devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835c9145a2a186d828457ff340e82a8"
PR = "r0"

inherit systemd

SRC_URI += "file://spektrum-sbc.env"

S = "${WORKDIR}"
SPEKTRUM_REPO_ROOT = "${THISDIR}/../../../../"
SPEKTRUM_SBC_DIR = "${SPEKTRUM_REPO_ROOT}/scripts/sbc"
SPEKTRUM_PORTAL_DIR = "${SPEKTRUM_SBC_DIR}/portal"

SYSTEMD_SERVICE:${PN} = "spektrum-first-boot.service spektrum-autonomous.service spektrum-device-info.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = " \
    bash \
    coreutils \
    curl \
    iproute2 \
    python3-core \
    python3-json \
    python3-sqlite3 \
    python3-websockets \
"

do_install() {
    install -d ${D}/opt/spektrum/scripts/sbc/portal
    install -d ${D}${systemd_system_unitdir}
    install -d ${D}${sysconfdir}/spektrum
    install -d ${D}${localstatedir}/lib/spektrum

    install -m 0755 ${SPEKTRUM_SBC_DIR}/autonomous_bootstrap.sh ${D}/opt/spektrum/scripts/sbc/
    install -m 0755 ${SPEKTRUM_SBC_DIR}/collect_logs.sh ${D}/opt/spektrum/scripts/sbc/
    install -m 0755 ${SPEKTRUM_SBC_DIR}/first_boot_setup.sh ${D}/opt/spektrum/scripts/sbc/

    install -m 0644 ${SPEKTRUM_SBC_DIR}/device_agent.py ${D}/opt/spektrum/scripts/sbc/
    install -m 0644 ${SPEKTRUM_SBC_DIR}/provisioning_server.py ${D}/opt/spektrum/scripts/sbc/
    install -m 0644 ${SPEKTRUM_SBC_DIR}/state_store.py ${D}/opt/spektrum/scripts/sbc/

    install -m 0644 ${SPEKTRUM_SBC_DIR}/spektrum-autonomous.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${SPEKTRUM_SBC_DIR}/spektrum-device-info.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${SPEKTRUM_SBC_DIR}/spektrum-first-boot.service ${D}${systemd_system_unitdir}/

    install -m 0644 ${SPEKTRUM_PORTAL_DIR}/index.html ${D}/opt/spektrum/scripts/sbc/portal/
    install -m 0644 ${SPEKTRUM_PORTAL_DIR}/app.js ${D}/opt/spektrum/scripts/sbc/portal/
    install -m 0644 ${SPEKTRUM_PORTAL_DIR}/styles.css ${D}/opt/spektrum/scripts/sbc/portal/

    install -m 0644 ${WORKDIR}/spektrum-sbc.env ${D}${sysconfdir}/spektrum/spektrum.env
    cat >${D}${sysconfdir}/spektrum/first-boot.env <<'EOF'
# Optional first-boot values
# SPEKTRUM_DEVICE_SECRET=
# SPEKTRUM_TAILSCALE_AUTHKEY=
EOF
}

CONFFILES:${PN} += " \
    ${sysconfdir}/spektrum/spektrum.env \
    ${sysconfdir}/spektrum/first-boot.env \
"

FILES:${PN} += " \
    /opt/spektrum/scripts/sbc/autonomous_bootstrap.sh \
    /opt/spektrum/scripts/sbc/collect_logs.sh \
    /opt/spektrum/scripts/sbc/first_boot_setup.sh \
    /opt/spektrum/scripts/sbc/device_agent.py \
    /opt/spektrum/scripts/sbc/provisioning_server.py \
    /opt/spektrum/scripts/sbc/state_store.py \
    /opt/spektrum/scripts/sbc/portal \
    ${systemd_system_unitdir}/spektrum-autonomous.service \
    ${systemd_system_unitdir}/spektrum-device-info.service \
    ${systemd_system_unitdir}/spektrum-first-boot.service \
    ${sysconfdir}/spektrum \
    ${localstatedir}/lib/spektrum \
"
