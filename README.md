## Headless Kali Cloud VM: ScreenConnect Desktop Fix Runbook

_Provisioning notes and ScreenConnect fix for Azure-hosted Kali VMs._

### The Problem

A Kali cloud VM built in Azure comes up headless, meaning it has no graphical desktop running and no real display hardware behind it. When you install the ScreenConnect client and try to join the session, all you see is a blinking root prompt on the text console (`tty1`) that will not accept any keyboard or mouse input. The VM is not frozen; you can SSH into it and work normally. The graphical session simply is not there for ScreenConnect to show you.

_There are two distinct faults stacked on top of each other:_

* **No X server is running:** The cloud image is headless, and the login manager (`lightdm`) refuses to launch Xorg because Azure presents no GPU for it to bind to.
* **Missing DISPLAY variable:** Even once an X server is running, the ScreenConnect service has no `DISPLAY` value in its environment, so it falls back to capturing the raw text console instead of the desktop.

### Before You Start

* The ScreenConnect (ConnectWise Control) client must already be installed on the VM before you apply this fix. Install it by building a Linux installer from your ScreenConnect Access page (*Build+*), downloading the resulting `.deb`, and executing:
```bash
sudo dpkg -i <installer>.deb

```


* Working outbound networking is required. Confirm the VM can reach the internet before proceeding:
```bash
curl -I https://google.com

```



---

## Step-by-Step Fix

_The manual steps are documented below to explain what the fix does and to allow targeted troubleshooting if a step misbehaves._

### Step 1 - Install the Dummy Video Driver

This driver lets Xorg run against a virtual display with no GPU present:

```bash
sudo apt update && sudo apt install -y xserver-xorg-video-dummy

```

### Step 2 - Write the Dummy Display Config

Create `/etc/X11/xorg.conf.d/10-dummy.conf` describing a virtual 1920x1080 screen. Use a here-document rather than a text editor to prevent clipboard corruption over SSH chains:

```bash
sudo mkdir -p /etc/X11/xorg.conf.d
sudo tee /etc/X11/xorg.conf.d/10-dummy.conf > /dev/null << 'EOF'
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

```

### Step 3 - Run X and XFCE as a Persistent Service

Disable `lightdm` so it does not compete for the display, then create a systemd unit to handle Xorg and XFCE under process supervision:

```bash
sudo systemctl disable --now lightdm

sudo tee /etc/systemd/system/headless-desktop.service > /dev/null << 'EOF'
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

sudo systemctl daemon-reload
sudo systemctl enable --now headless-desktop.service

```

Confirm the X socket exists:

```bash
ls -la /tmp/.X11-unix/

```

*Expect output showing `X0`.*

### Step 4 - Point ScreenConnect at the Display

Inject `DISPLAY=:0` into the ScreenConnect service environment using a systemd drop-in override:

```bash
SC_UNIT=$(systemctl list-units --type=service --all --no-legend 'connectwisecontrol-*' | awk '{print $1}' | head -n1)

sudo mkdir -p /etc/systemd/system/${SC_UNIT}.d
sudo tee /etc/systemd/system/${SC_UNIT}.d/override.conf > /dev/null << 'EOF'
[Service]
Environment=DISPLAY=:0
Environment=XAUTHORITY=/root/.Xauthority
EOF

sudo systemctl daemon-reload
sudo systemctl restart ${SC_UNIT}

```

Wait ~10 seconds, then **Join** the machine in ScreenConnect. The XFCE desktop should render and accept input.

---

## Verification

Run the following validation commands:

```bash
ls /tmp/.X11-unix/                     # Expect: X0
systemctl status headless-desktop      # Expect: active (running)
systemctl status connectwisecontrol-*  # Expect: active (running)

```

---

## Technical Gotchas

* **Empty X socket is a timing artifact, not a failure:** Checking `/tmp/.X11-unix/` during a crash loop or immediately after manual `startx` execution can show an empty directory if the shell exited. Supervised under systemd with `Restart=always`, the socket holds. Check `journalctl -u headless-desktop` rather than relying solely on socket presence.
* **The `tty1` prompt indicates a display routing error:** A non-interactive blinking root prompt means ScreenConnect is reading the console framebuffer instead of the X session. The desktop can be active simultaneously; the resolution is strictly the `DISPLAY` environment override in Step 4.
* **Do not disable NLA on Domain Controllers:** If requested during troubleshooting to weaken Network Level Authentication on a DC to facilitate RDP access, decline. This degrades security posture and does not fix client-side credential passthrough issues.
* **Avoid interactive text editors for config files:** Pasting multi-line definitions into `nano` or `vi` across remote shells introduces line splits and truncation. `sudo tee` with here-documents ensures atomicity.
* **`setuptools` >=82 breaks Impacket:** If Impacket fails with `No module named 'pkg_resources'`, pin the environment:
```bash
pip install "setuptools<81"

```


Recent `setuptools` releases removed the legacy `pkg_resources` submodule.

---

## Azure Networking Requirements

_If a newly provisioned VM lacks outbound network connectivity, verify Azure route tables and VNet settings._

### Symptoms

`ip route` shows no default gateway, and `resolvectl status` shows no DNS servers with `Default Route: no`.

### Temporary In-VM Workaround

Manually assign DNS and domain routing (non-persistent across rebuilds):

```bash
sudo resolvectl dns eth0 <DC_IP_1> <DC_IP_2>
sudo resolvectl domain eth0 <ad.domain.local>

```

### Permanent Fix

_Configure infrastructure on the Azure side:_

1. Attach the Virtual NIC to a subnet with an active route to the Internet.
2. Allow outbound **TCP 443** in the Network Security Group (NSG).
3. Point VNet DNS settings directly to the Domain Controllers.

---

## Deployment Recommendations

Bake these four display steps into base images or cloud-init provisioning scripts to ensure instance readiness upon deployment. Retain Azure networking parameters inside Terraform/ARM templates to eliminate manual post-provisioning remediation.
