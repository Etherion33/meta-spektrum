SUMMARY = "Spektrum SBC core runtime"
DESCRIPTION = "Core provisioning, state handling, and systemd runtime for Spektrum SBC devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r0"

# Baked into /etc/spektrum/first-boot.env at build time.
# Override in local.conf: SPEKTRUM_DEVICE_SECRET = "your-secret-here"
SPEKTRUM_DEVICE_SECRET ?= ""
SPEKTRUM_TAILSCALE_AUTHKEY ?= ""

inherit allarch systemd

SRC_URI += " \
    file://spektrum-sbc.env \
    file://spektrum-sbc.tmpfiles.conf \
    file://spektrum-runtime.target \
    file://autonomous_bootstrap.sh \
    file://collect_logs.sh \
    file://first_boot_setup.sh \
    file://device_agent.py \
    file://provisioning_server.py \
    file://state_store.py \
    file://spektrum-autonomous.service \
    file://spektrum-device-info.service \
    file://spektrum-first-boot.service \
    file://portal/index.html \
    file://portal/app.js \
    file://portal/styles.css \
"

S = "${WORKDIR}"
SPEKTRUM_CORE_PYTHON_RDEPENDS ?= " \
    python3-core \
    python3-sqlite3 \
    python3-websockets \
"

SYSTEMD_SERVICE:${PN} = "spektrum-runtime.target spektrum-first-boot.service spektrum-autonomous.service spektrum-device-info.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} = " \
    bash \
    coreutils \
    curl \
    iproute2 \
    ${SPEKTRUM_CORE_PYTHON_RDEPENDS} \
"

do_install() {
    install -d ${D}/opt/spektrum/scripts/sbc/portal
    install -d ${D}${systemd_system_unitdir}
    install -d ${D}${sysconfdir}/spektrum
    install -d ${D}${nonarch_libdir}/tmpfiles.d

    install -m 0755 ${WORKDIR}/autonomous_bootstrap.sh ${D}/opt/spektrum/scripts/sbc/
    install -m 0755 ${WORKDIR}/collect_logs.sh ${D}/opt/spektrum/scripts/sbc/
    install -m 0755 ${WORKDIR}/first_boot_setup.sh ${D}/opt/spektrum/scripts/sbc/

    install -m 0644 ${WORKDIR}/device_agent.py ${D}/opt/spektrum/scripts/sbc/
    install -m 0644 ${WORKDIR}/provisioning_server.py ${D}/opt/spektrum/scripts/sbc/
    install -m 0644 ${WORKDIR}/state_store.py ${D}/opt/spektrum/scripts/sbc/

    install -m 0644 ${WORKDIR}/spektrum-autonomous.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/spektrum-device-info.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/spektrum-first-boot.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/spektrum-runtime.target ${D}${systemd_system_unitdir}/

    install -m 0644 ${WORKDIR}/portal/index.html ${D}/opt/spektrum/scripts/sbc/portal/
    install -m 0644 ${WORKDIR}/portal/app.js ${D}/opt/spektrum/scripts/sbc/portal/
    install -m 0644 ${WORKDIR}/portal/styles.css ${D}/opt/spektrum/scripts/sbc/portal/

    install -m 0644 ${WORKDIR}/spektrum-sbc.env ${D}${sysconfdir}/spektrum/spektrum.env
    install -m 0644 ${WORKDIR}/spektrum-sbc.tmpfiles.conf ${D}${nonarch_libdir}/tmpfiles.d/spektrum-sbc.conf
    {
        printf 'SPEKTRUM_DEVICE_SECRET=%s\n' "${SPEKTRUM_DEVICE_SECRET}"
        printf 'SPEKTRUM_TAILSCALE_AUTHKEY=%s\n' "${SPEKTRUM_TAILSCALE_AUTHKEY}"
    } > ${D}${sysconfdir}/spektrum/first-boot.env
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
    ${systemd_system_unitdir}/spektrum-runtime.target \
    ${nonarch_libdir}/tmpfiles.d/spektrum-sbc.conf \
    ${sysconfdir}/spektrum \
"
