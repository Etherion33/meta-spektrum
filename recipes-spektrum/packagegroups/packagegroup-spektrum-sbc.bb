SUMMARY = "Spektrum SBC package group"
LICENSE = "MIT"
PR = "r1"

inherit packagegroup

RDEPENDS:${PN} = " \
    spektrum-sbc \
    spektrum-sbc-oled \
    i2c-tools \
"
