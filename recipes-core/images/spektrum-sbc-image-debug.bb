SUMMARY = "Spektrum SBC debug image"
LICENSE = "MIT"

require recipes-core/images/core-image-base.bb

COMPATIBLE_MACHINE = "^radxa-zero$"
ENABLE_UART = "1"

IMAGE_FEATURES:append = " \
    ssh-server-openssh \
    debug-tweaks \
    tools-debug \
    dev-pkgs \
    dbg-pkgs \
    splash \
"

IMAGE_INSTALL:append = " \
    packagegroup-spektrum-sbc \
    iperf3 \
    htop \
    net-tools \
"

IMAGE_FEATURES:remove = "read-only-rootfs"
