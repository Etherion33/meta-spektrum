# Spektrum distro-level defaults.
# Keep recipe logic simple by centralizing policy knobs here.

# Default Spektrum feature set for the meta package.
PACKAGECONFIG:pn-spektrum-sbc ??= "network streaming"

# Optional features can be toggled from distro/local config.
SPEKTRUM_ENABLE_OLED ?= "0"
SPEKTRUM_ENABLE_TAILSCALE ?= "0"

PACKAGECONFIG:append:pn-spektrum-sbc = "${@bb.utils.contains('SPEKTRUM_ENABLE_OLED', '1', ' oled', '', d)}"
PACKAGECONFIG:append:pn-spektrum-sbc = "${@bb.utils.contains('SPEKTRUM_ENABLE_TAILSCALE', '1', ' tailscale', '', d)}"

# Python package split defaults (override if your layer names differ).
SPEKTRUM_CORE_PYTHON_RDEPENDS ?= "python3-core python3-sqlite3 python3-websockets"
SPEKTRUM_OLED_PYTHON_RDEPENDS ?= "python3-core python3-sqlite3 python3-cbor2 python3-pillow python3-luma-oled"

# GStreamer package split defaults (override per distro/layer mix).
SPEKTRUM_STREAMING_RDEPENDS ?= "gstreamer1.0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav v4l-utils"