SUMMARY = "Spektrum SBC streaming dependencies"
DESCRIPTION = "Streaming and camera runtime dependencies for Spektrum SBC devices"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"
PR = "r0"

inherit allarch

ALLOW_EMPTY:${PN} = "1"
SPEKTRUM_STREAMING_RDEPENDS ?= " \
    gstreamer1.0 \
    gstreamer1.0-plugins-base \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-libav \
    v4l-utils \
"

RDEPENDS:${PN} = " \
    ${SPEKTRUM_STREAMING_RDEPENDS} \
"
