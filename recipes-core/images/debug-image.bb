# Base this image on core-image-base
include recipes-core/images/core-image-base.bb

COMPATIBLE_MACHINE = "^radxa-zero$"

ENABLE_UART = "1"

# Debug-specific settings and features
IMAGE_FEATURES:append = " \
    ssh-server-openssh \
    debug-tweaks \
    tools-debug \
    dev-pkgs \
    dbg-pkgs \
    splash \
"
# 'dev-pkgs': Installs -dev packages (headers, static libs) for on-target development.
# 'dbg-pkgs': Installs -dbg packages (debugging symbols) for packages in the image.
# 'tools-debug': Installs gdb, strace, etc.
# 'debug-tweaks': Various tweaks helpful for debugging, like allowing passwordless root login.

# Add debugging utilities and package groups
IMAGE_INSTALL:append = " \
    iperf3 \
    htop \
    net-tools \
"

# You might want a writable root filesystem for debugging
IMAGE_FEATURES:remove = "read-only-rootfs"
