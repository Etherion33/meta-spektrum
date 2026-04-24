# meta-spektrum

Second-pass Yocto layer for the Spektrum SBC runtime.

## Current structure

- spektrum-sbc-core for the portal, state handling, main runtime, and mandatory services
- spektrum-sbc-network for AP and STA helper scripts
- spektrum-sbc-streaming for media runtime dependencies
- optional feature packages for OLED and Tailscale integration
- spektrum-sbc as a selectable meta package for image inclusion

## Quick start

1. Add the layer to your build:

   bitbake-layers add-layer ../spektrum-stack/meta-spektrum

   This layer expects `meta-python` to be present for Python runtime packages such as `python3-websockets`, `python3-pillow`, and `python3-luma-oled`.

   This layer also ships a distro config at `conf/distro/cheesecake.conf`.

2. Enable the distro in your build config:

   DISTRO = "cheesecake"

   The distro pulls Spektrum defaults from `conf/distro/include/cheesecake-spektrum.inc`.

3. Add the meta package or packagegroup to your image:

   IMAGE_INSTALL:append = " packagegroup-spektrum-sbc"

4. Choose features as needed:

   Defaults from the distro are:
   PACKAGECONFIG:pn-spektrum-sbc = "network streaming"

   Optional toggles from distro/local config:
   SPEKTRUM_ENABLE_OLED = "1"
   SPEKTRUM_ENABLE_TAILSCALE = "1"

   The `tailscale` feature expects a `tailscale` package from another layer such as `meta-tailscale`.

5. Optionally override runtime values with:

   - /etc/spektrum/spektrum.env
   - /etc/spektrum/first-boot.env

6. If your Python layer exports different package names, override the dependency variables in your distro or local configuration:

   SPEKTRUM_CORE_PYTHON_RDEPENDS = "python3-core python3-sqlite3 python3-websockets"
   SPEKTRUM_OLED_PYTHON_RDEPENDS = "python3-core python3-sqlite3 python3-pillow python3-luma-oled"

7. If your GStreamer package split differs across layers, override the streaming dependency variable as well:

   SPEKTRUM_STREAMING_RDEPENDS = "gstreamer1.0 gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad gstreamer1.0-plugins-ugly gstreamer1.0-libav v4l-utils"

8. If you need desktop graphics for a dev image, re-enable them explicitly since the distro removes `x11` and `wayland` by default.

## Image profiles

This layer now provides two image recipes:

- `spektrum-sbc-image-debug`: developer-focused image with `debug-tweaks`, debug tools, extra packages, and writable rootfs.
- `spektrum-sbc-image-prod`: hardened image with `read-only-rootfs` and no debug tweaks.

Compatibility note:

- `spektrum-sbc-image` remains available and aliases to `spektrum-sbc-image-prod`.

Build examples:

- `bitbake spektrum-sbc-image-debug`
- `bitbake spektrum-sbc-image-prod`

Production password policy:

- `spektrum-sbc-image-prod` does not hardcode any password hash.
- To set one, provide `SPEKTRUM_ROOT_PASSWORD_HASH` from a private layer, CI variable, or secure local config.
- Example in `local.conf` (hash value shown only as placeholder):

   `SPEKTRUM_ROOT_PASSWORD_HASH = "$6$<salt>$<hash>"`

## Notes

This pass keeps the current behavior but splits the Yocto packaging into cleaner functional boundaries and reduces hardcoded runtime assumptions. The Tailscale recipe only provides Spektrum-specific enrollment glue and assumes the actual `tailscale` package is supplied externally.

The current streaming pipeline uses `v4l2src`, `videoconvert`, `jpegdec`, `x264enc`, `h264parse`, and `rtspclientsink`. In practice, that usually means the exact GStreamer package set depends on how your Yocto layers split GStreamer plugins, so `SPEKTRUM_STREAMING_RDEPENDS` is intended to be overridden per distro or layer mix.

First-boot simplification implemented:

- `first_boot_setup.sh` now focuses on one-time state initialization only.
- Service enable/start behavior is owned by recipe `SYSTEMD_SERVICE` and `SYSTEMD_AUTO_ENABLE` metadata.
- Runtime directory creation is owned by `tmpfiles.d` (`spektrum-sbc.tmpfiles.conf`) instead of shell logic.

This reduces first-boot script churn when service composition changes and makes policy easier to maintain in distro/recipe metadata.

Service organization redesign:

- `spektrum-runtime.target` now owns runtime composition.
- `spektrum-first-boot.service` runs before the runtime target and remains a one-time initializer.
- `spektrum-autonomous.service`, `spektrum-device-info.service`, and optional `spektrum-oled-status.service` are attached to the runtime target (`WantedBy=spektrum-runtime.target`, `PartOf=spektrum-runtime.target`).

This gives a cleaner boot graph and keeps service wiring in systemd unit metadata instead of shell scripts.

AP/STA and Tailscale coexistence note:

- `autonomous_bootstrap.sh` now checks backend reachability over Wi-Fi by default (`SPEKTRUM_BACKEND_CHECK_VIA_WIFI_ONLY=1`).
- This avoids false positives where backend checks pass through a Tailscale route even when STA/AP state is wrong.
- OLED IP selection now avoids Tailscale CGNAT addresses (`100.64.0.0/10`) and prefers Wi-Fi/Ethernet interface addresses.

Optional overrides in `spektrum.env`:

- `SPEKTRUM_BACKEND_CHECK_VIA_WIFI_ONLY=0` to allow any default route for backend checks.
- `SPEKTRUM_BACKEND_CHECK_INTERFACE=<iface>` to force a specific interface (default is `${SPEKTRUM_WLAN_IFACE}`).
