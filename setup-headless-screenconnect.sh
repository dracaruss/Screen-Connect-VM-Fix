#!/usr/bin/env bash
#
# setup-headless-screenconnect.sh
#
# Makes a headless Kali cloud VM (e.g. on Azure, no real GPU) show a usable
# XFCE desktop through ScreenConnect instead of a frozen tty1 text console.
#
# Run this AFTER the ScreenConnect client is already installed on the VM,
# because the script points that existing service at the X display.
#
# Safe to re-run: every step is idempotent (checks/overwrites rather than
# appends), so running it twice does no harm.
#
# What it does, in order:
#   1. Installs the Xorg "dummy" video driver (lets X run with no GPU).
#   2. Writes a dummy display config so Xorg has a virtual 1920x1080 screen.
#   3. Runs X + XFCE as a persistent systemd service on display :0
#      (bypasses lightdm, which never launches X on this image).
#   4. Gives the ScreenConnect service DISPLAY=:0 via a drop-in override,
#      so it captures the real desktop instead of the console.
#
# NOTE: This covers the display + ScreenConnect half only. Azure-side
# networking (default gateway, DNS pointing at the DCs) is set in the
# Azure portal / vnet and is NOT handled here.

set -euo pipefail

# --- must run as root -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[!] Please run with sudo:  sudo $0"
    exit 1
fi

echo "[*] Step 1: installing xserver-xorg-video-dummy ..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y xserver-xorg-video-dummy

echo "[*] Step 2: writing dummy Xorg config ..."
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/10-dummy.conf << 'EOF'
Section "Device"
    Identifier  "DummyDevice"
    Driver      "dummy"
    VideoRam    256000
EndSection

Section "Monitor"
    Identifier  "DummyMonitor"
    HorizSync   5.0 - 1000.0
    VertRefresh 5.0 - 200.0
EndSection

Section "Screen"
    Identifier  "DummyScreen"
    Device      "DummyDevice"
    Monitor     "DummyMonitor"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1920x1080"
    EndSubSection
EndSection
EOF

echo "[*] Step 3: creating headless X + XFCE systemd service ..."
# lightdm never launches X on this cloud image, so disable it if present
# and run X+XFCE ourselves under systemd with auto-restart.
systemctl disable --now lightdm 2>/dev/null || true

cat > /etc/systemd/system/headless-desktop.service << 'EOF'
[Unit]
Description=Headless X and XFCE on dummy display
After=multi-user.target

[Service]
User=root
Environment=DISPLAY=:0
ExecStart=/usr/bin/xinit /usr/bin/xfce4-session -- /usr/bin/X :0 -config /etc/X11/xorg.conf.d/10-dummy.conf
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now headless-desktop.service

echo "[*] Step 4: pointing ScreenConnect at display :0 ..."
# Auto-detect the ScreenConnect (ConnectWise Control) service name. The GUID
# differs per VM, so we discover it rather than hard-code it.
SC_UNIT="$(systemctl list-units --type=service --all --no-legend 'connectwisecontrol-*' \
            | awk '{print $1}' | head -n1)"

if [[ -z "${SC_UNIT}" ]]; then
    echo "[!] No connectwisecontrol-* service found."
    echo "    Install the ScreenConnect client first, then re-run this script."
    echo "    The desktop service is up regardless; only the SC override was skipped."
    exit 1
fi

echo "    Found ScreenConnect service: ${SC_UNIT}"
OVERRIDE_DIR="/etc/systemd/system/${SC_UNIT}.d"
mkdir -p "${OVERRIDE_DIR}"
cat > "${OVERRIDE_DIR}/override.conf" << 'EOF'
[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=/root/.Xauthority
EOF

systemctl daemon-reload
systemctl restart "${SC_UNIT}"

echo
echo "[+] Done. Give it ~10 seconds, then Join the machine in ScreenConnect."
echo "[+] It should show the XFCE desktop and accept keyboard/mouse."
echo
echo "    Quick local checks:"
echo "      ls /tmp/.X11-unix/                 # expect: X0"
echo "      systemctl status headless-desktop  # expect: active (running)"
echo "      systemctl status ${SC_UNIT}"
