SUMMARY = "Spektrum SBC production image"
LICENSE = "MIT"

require recipes-core/images/core-image-base.bb

COMPATIBLE_MACHINE = "^radxa-zero$"
ENABLE_UART = "0"

IMAGE_INSTALL:append = " \
    packagegroup-spektrum-sbc \
    linux-firmware-bcm43430 \
    linux-firmware-bcm43430a0 \
    linux-firmware-bcm-0bb4-0306 \
"

IMAGE_FEATURES:remove = "debug-tweaks"
EXTRA_IMAGE_FEATURES:remove = "debug-tweaks"
IMAGE_FEATURES:append = " read-only-rootfs"

# Do not hardcode production passwords/secrets in this layer.
# If needed, set SPEKTRUM_ROOT_PASSWORD_HASH from a private layer or CI secret.
inherit extrausers
SPEKTRUM_ROOT_PASSWORD_HASH ?= ""
EXTRA_USERS_PARAMS = "${@bb.utils.contains('SPEKTRUM_ROOT_PASSWORD_HASH', '', '', 'usermod -p \'${SPEKTRUM_ROOT_PASSWORD_HASH}\' root;', d)}"
