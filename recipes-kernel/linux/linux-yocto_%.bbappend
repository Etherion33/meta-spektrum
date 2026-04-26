FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI += " \
    file://0001-arm64-dts-meson-g12a-radxa-zero-enable-i2c3-and-led.patch \
    file://i2c-char-dev.cfg \
"
