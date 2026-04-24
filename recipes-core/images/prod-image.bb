# Base this image on core-image-base
include recipes-core/images/core-image-base.bb

COMPATIBLE_MACHINE = "^radxa-zero$"

ENABLE_UART = "0"

IMAGE_FEATURES:remove = "debug-tweaks splash"
EXTRA_IMAGE_FEATURES:remove = "debug-tweaks"
IMAGE_FEATURES:append = " read-only-rootfs" 

inherit extrausers
EXTRA_USERS_PARAMS = "\
    usermod -p '\$6\$Qfjjnmtb4mIZWAfj\$YmMw6bQ2xThFSslyQN6VEV4wf/7BtvALbA4fddU07IfGGic0tAy5wFvItzXVGhwxCxy0C5MIfz0lOEH2k3wYi1' root; \
    "

