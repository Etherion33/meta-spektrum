# meta-spektrum linux-firmware bbappend
#
# Fixes BCM43430A1 (AP6212) Wi-Fi on Radxa Zero:
#   meta-meson installs the 2018 LibreELEC brcmfmac43430-sdio.bin which is
#   incompatible with the modern cypress CLM blob, causing a -110 timeout.
#   We replace it with the cypress/cyfmac43430-sdio.bin from the upstream
#   linux-firmware package (same build, version-matched to the CLM blob).
#
# Also adds BCM43430A1.hcd (Bluetooth) from the LibreELEC repo (available in
# WORKDIR as BCM43438A1.hcd — same firmware, different naming convention).

do_install:append() {
    # Replace old LibreELEC firmware binary with the upstream cypress version.
    # cyfmac43430-sdio.bin and cyfmac43430-sdio.clm_blob come from the same
    # linux-firmware release, so they are version-matched.
    install -m 0644 \
        ${D}${nonarch_base_libdir}/firmware/cypress/cyfmac43430-sdio.bin \
        ${D}${nonarch_base_libdir}/firmware/brcm/brcmfmac43430-sdio.bin

    # Install Bluetooth HCD firmware for BCM43430A1 (AP6212 module on Radxa Zero).
    # The LibreELEC repo (fetched by meta-meson) provides this as BCM43438A1.hcd.
    if [ -f ${WORKDIR}/brcmfmac_sdio-firmware/BCM43438A1.hcd ]; then
        install -m 0644 \
            ${WORKDIR}/brcmfmac_sdio-firmware/BCM43438A1.hcd \
            ${D}${nonarch_base_libdir}/firmware/brcm/BCM43430A1.hcd
    fi
}

FILES:${PN}-bcm43430 += " \
    ${nonarch_base_libdir}/firmware/brcm/BCM43430A1.hcd \
"
