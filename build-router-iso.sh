#!/bin/bash
###############################################################################
# build-router-iso.sh
#
# Builds a minimal Ubuntu-based router/network OS ISO image
# with multi-interface, VLAN, VRF, and VyOS-like config management
#
# Requirements:
#   - Ubuntu 22.04+ build host
#   - Root access (or sudo)
#   - ~10GB free disk space
#   - Internet access for package downloads
#
# Usage:
#   sudo ./build-router-iso.sh [OPTIONS]
#
# Options:
#   --name NAME          Distribution name (default: "NetRouter OS")
#   --version VER        Version string (default: "1.0.0")
#   --arch ARCH          Architecture (default: amd64)
#   --ubuntu-release REL Ubuntu base release (default: noble = 24.04)
#   --output DIR         Output directory (default: ./output)
#   --extra-packages PKG Comma-separated extra packages to include
#   --no-cleanup         Don't clean up build directory
#   --vm-image           Also build a qcow2 VM image
#
# Example:
#   sudo ./build-router-iso.sh --name "MyRouter" --version "2.0" --vm-image
###############################################################################

set -euo pipefail

# ---- Configuration ----
DISTRO_NAME="${DISTRO_NAME:-NetRouter OS}"
DISTRO_VERSION="${DISTRO_VERSION:-1.0.0}"
ARCH="${ARCH:-amd64}"
UBUNTU_RELEASE="${UBUNTU_RELEASE:-noble}"
UBUNTU_MIRROR="http://archive.ubuntu.com/ubuntu"
OUTPUT_DIR="${OUTPUT_DIR:-./output}"
BUILD_DIR="/tmp/router-iso-build-$$"
ROOTFS="${BUILD_DIR}/rootfs"
ISO_DIR="${BUILD_DIR}/iso"
BUILD_VM_IMAGE=false
CLEANUP=true
EXTRA_PACKAGES=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --name) DISTRO_NAME="$2"; shift 2 ;;
        --version) DISTRO_VERSION="$2"; shift 2 ;;
        --arch) ARCH="$2"; shift 2 ;;
        --ubuntu-release) UBUNTU_RELEASE="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --extra-packages) EXTRA_PACKAGES="$2"; shift 2 ;;
        --no-cleanup) CLEANUP=false; shift ;;
        --vm-image) BUILD_VM_IMAGE=true; shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

SAFE_NAME=$(echo "$DISTRO_NAME" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
ISO_FILENAME="${SAFE_NAME}-${DISTRO_VERSION}-${ARCH}.iso"

log() { echo -e "\n\033[1;36m===> $1\033[0m"; }
warn() { echo -e "\033[1;33mWARN: $1\033[0m"; }
err() { echo -e "\033[1;31mERROR: $1\033[0m"; exit 1; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "This script must be run as root (sudo)"
    fi
}

# ---- Step 0: Install build dependencies ----
install_build_deps() {
    log "Installing build dependencies"
    apt-get update -qq
    apt-get install -y -qq \
        debootstrap \
        squashfs-tools \
        xorriso \
        grub-pc-bin \
        grub-efi-amd64-bin \
        grub-efi-amd64-signed \
        shim-signed \
        mtools \
        dosfstools \
        isolinux \
        syslinux-utils \
        qemu-utils 2>/dev/null || true
}

# ---- Step 1: Bootstrap minimal rootfs ----
bootstrap_rootfs() {
    log "Bootstrapping Ubuntu ${UBUNTU_RELEASE} (${ARCH}) rootfs"
    mkdir -p "${ROOTFS}"

    debootstrap \
        --arch="${ARCH}" \
        --variant=minbase \
        --components=main,restricted,universe \
        --include=apt,apt-utils,systemd,systemd-sysv,dbus,sudo,locales,ca-certificates \
        "${UBUNTU_RELEASE}" \
        "${ROOTFS}" \
        "${UBUNTU_MIRROR}"
}

# ---- Step 2: Configure rootfs ----
configure_rootfs() {
    log "Configuring rootfs"

    # Mount virtual filesystems
    mount --bind /dev "${ROOTFS}/dev"
    mount --bind /dev/pts "${ROOTFS}/dev/pts"
    mount -t proc proc "${ROOTFS}/proc"
    mount -t sysfs sysfs "${ROOTFS}/sys"

    # DNS for chroot
    cp /etc/resolv.conf "${ROOTFS}/etc/resolv.conf"

    # APT sources
    cat > "${ROOTFS}/etc/apt/sources.list" <<EOF
deb ${UBUNTU_MIRROR} ${UBUNTU_RELEASE} main restricted universe
deb ${UBUNTU_MIRROR} ${UBUNTU_RELEASE}-updates main restricted universe
deb ${UBUNTU_MIRROR} ${UBUNTU_RELEASE}-security main restricted universe
EOF

    # Run config inside chroot
    chroot "${ROOTFS}" /bin/bash -e <<'CHROOTEOF'
export DEBIAN_FRONTEND=noninteractive

apt-get update -qq

# ---- Kernel ----
apt-get install -y -qq linux-image-generic linux-headers-generic

# ---- Core networking ----
apt-get install -y -qq \
    iproute2 \
    iptables \
    nftables \
    ethtool \
    net-tools \
    tcpdump \
    traceroute \
    mtr-tiny \
    iperf3 \
    vlan \
    bridge-utils \
    lldpd \
    conntrack \
    ipvsadm \
    ipset

# ---- Routing suite (FRRouting) ----
# Add FRR repo for latest version
apt-get install -y -qq curl gnupg lsb-release
curl -s https://deb.frrouting.org/frr/keys.gpg | tee /usr/share/keyrings/frrouting.gpg > /dev/null 2>&1 || true
UBUNTU_CODENAME=$(lsb_release -cs)
echo "deb [signed-by=/usr/share/keyrings/frrouting.gpg] https://deb.frrouting.org/frr ${UBUNTU_CODENAME} frr-stable" > /etc/apt/sources.list.d/frr.list
apt-get update -qq
apt-get install -y -qq frr frr-pythontools || apt-get install -y -qq frr

# ---- VPN ----
apt-get install -y -qq \
    wireguard-tools \
    strongswan \
    strongswan-pki \
    openvpn

# ---- DHCP / DNS ----
apt-get install -y -qq \
    dnsmasq \
    isc-dhcp-server || true

# ---- Monitoring / tools ----
apt-get install -y -qq \
    openssh-server \
    python3 \
    python3-pip \
    jq \
    htop \
    iotop \
    sysstat \
    lsof \
    strace \
    rsync \
    vim-tiny \
    less \
    tmux \
    cloud-init

# ---- GRUB ----
apt-get install -y -qq grub-efi-amd64 grub-pc-bin

# ---- Cleanup ----
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
CHROOTEOF
}

# ---- Step 3: Install router config system ----
install_config_system() {
    log "Installing router configuration system"

    # Create directory structure
    mkdir -p "${ROOTFS}/usr/local/lib/routeros"
    mkdir -p "${ROOTFS}/usr/local/bin"
    mkdir -p "${ROOTFS}/config"/{active,candidate,archive,boot}

    # Copy config manager
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    if [[ -f "${SCRIPT_DIR}/config-system/usr/local/lib/routeros/config_manager.py" ]]; then
        cp "${SCRIPT_DIR}/config-system/usr/local/lib/routeros/config_manager.py" \
           "${ROOTFS}/usr/local/lib/routeros/config_manager.py"
        cp "${SCRIPT_DIR}/config-system/usr/local/bin/routercli" \
           "${ROOTFS}/usr/local/bin/routercli"
        chmod +x "${ROOTFS}/usr/local/bin/routercli"
    else
        warn "Config system files not found at ${SCRIPT_DIR}/config-system — generating inline"
        # Fallback: create a minimal wrapper
        cat > "${ROOTFS}/usr/local/bin/routercli" <<'EOF'
#!/bin/bash
exec python3 /usr/local/lib/routeros/config_manager.py "$@"
EOF
        chmod +x "${ROOTFS}/usr/local/bin/routercli"
    fi

    # Install boot-time config loader
    cat > "${ROOTFS}/etc/systemd/system/router-config.service" <<EOF
[Unit]
Description=Load router configuration at boot
After=network-pre.target systemd-networkd.service
Before=network.target frr.service nftables.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/routercli load-boot
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    chroot "${ROOTFS}" systemctl enable router-config.service
}

# ---- Step 4: System hardening & tuning ----
harden_system() {
    log "Hardening and tuning system"

    # Kernel modules for routing
    cat > "${ROOTFS}/etc/modules-load.d/router.conf" <<EOF
8021q
vrf
veth
bridge
bonding
nf_conntrack
ip_tables
ip6_tables
EOF

    # Blacklist unnecessary modules
    cat > "${ROOTFS}/etc/modprobe.d/blacklist-router.conf" <<EOF
blacklist bluetooth
blacklist btusb
blacklist snd_pcm
blacklist snd_hda_intel
blacklist soundcore
blacklist usb_storage
blacklist firewire_core
blacklist floppy
blacklist pcspkr
EOF

    # Sysctl tuning for routing
    cat > "${ROOTFS}/etc/sysctl.d/99-router.conf" <<EOF
# IP forwarding
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096

# Connection tracking
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400

# Network buffers
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.netdev_max_backlog = 50000
net.core.somaxconn = 65535

# TCP tuning
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1

# ARP
net.ipv4.neigh.default.gc_thresh1 = 4096
net.ipv4.neigh.default.gc_thresh2 = 8192
net.ipv4.neigh.default.gc_thresh3 = 16384

# Log martians
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0

# VRF strict mode
net.vrf.strict_mode = 1
EOF

    # Enable FRR daemons
    cat > "${ROOTFS}/etc/frr/daemons" <<EOF
zebra=yes
bgpd=yes
ospfd=yes
ospf6d=yes
isisd=no
pimd=no
staticd=yes
vtysh_enable=yes
zebra_options="  -A 127.0.0.1 -s 90000000"
bgpd_options="   -A 127.0.0.1"
ospfd_options="  -A 127.0.0.1"
ospf6d_options=" -A ::1"
staticd_options="-A 127.0.0.1"
EOF

    chroot "${ROOTFS}" systemctl enable frr
    chroot "${ROOTFS}" systemctl enable nftables
    chroot "${ROOTFS}" systemctl enable ssh
    chroot "${ROOTFS}" systemctl enable systemd-networkd
    chroot "${ROOTFS}" systemctl enable lldpd

    # Disable unnecessary services
    chroot "${ROOTFS}" systemctl disable apt-daily.timer 2>/dev/null || true
    chroot "${ROOTFS}" systemctl disable apt-daily-upgrade.timer 2>/dev/null || true
    chroot "${ROOTFS}" systemctl mask snapd.service 2>/dev/null || true

    # Console-only target
    chroot "${ROOTFS}" systemctl set-default multi-user.target
}

# ---- Step 5: Setup users & login ----
setup_users() {
    log "Setting up users and login"

    # Set root password (change in production!)
    chroot "${ROOTFS}" bash -c 'echo "root:router" | chpasswd'

    # Create admin user
    chroot "${ROOTFS}" useradd -m -s /bin/bash -G sudo,frr,frrvty admin
    chroot "${ROOTFS}" bash -c 'echo "admin:admin" | chpasswd'

    # MOTD / login banner
    cat > "${ROOTFS}/etc/motd" <<EOF

  ╔══════════════════════════════════════════╗
  ║         ${DISTRO_NAME} v${DISTRO_VERSION}            ║
  ║                                          ║
  ║   Type 'routercli' for configuration     ║
  ║   Type 'vtysh' for routing shell         ║
  ╚══════════════════════════════════════════╝

EOF

    cat > "${ROOTFS}/etc/issue" <<EOF
${DISTRO_NAME} v${DISTRO_VERSION} \\n \\l

EOF

    # Auto-show status on login
    cat > "${ROOTFS}/etc/profile.d/router-status.sh" <<'EOF'
#!/bin/bash
if [ -t 1 ]; then
    echo ""
    echo "Interfaces:"
    ip -br addr show 2>/dev/null | head -20
    echo ""
    echo "VRFs:"
    ip vrf show 2>/dev/null || echo "  (none)"
    echo ""
    echo "Routing:"
    vtysh -c "show ip route summary" 2>/dev/null || echo "  FRR not running"
    echo ""
fi
EOF
    chmod +x "${ROOTFS}/etc/profile.d/router-status.sh"

    # Bash aliases for convenience
    cat > "${ROOTFS}/etc/profile.d/router-aliases.sh" <<'EOF'
alias conf='routercli'
alias show-routes='ip route show'
alias show-vrfs='ip vrf show'
alias show-vlans='cat /proc/net/vlan/config 2>/dev/null || echo "No VLANs"'
alias show-fw='nft list ruleset'
alias show-ifaces='ip -br addr show'
alias show-neighbors='vtysh -c "show ip bgp summary" 2>/dev/null; lldpctl 2>/dev/null'
EOF
}

# ---- Step 6: Prepare /config partition (persistent) ----
setup_config_partition() {
    log "Setting up persistent config partition"

    # fstab entry for config partition
    cat >> "${ROOTFS}/etc/fstab" <<EOF
# Persistent config partition
LABEL=CONFIG  /config  ext4  defaults,noatime  0  2
EOF

    # First-boot script to initialize config if needed
    cat > "${ROOTFS}/usr/local/bin/first-boot-config.sh" <<'EOF'
#!/bin/bash
# Initialize config on first boot if empty
if [ ! -f /config/active/config.json ]; then
    mkdir -p /config/{active,candidate,archive,boot}
    routercli edit
    routercli save
    echo "First boot: default config initialized."
fi
EOF
    chmod +x "${ROOTFS}/usr/local/bin/first-boot-config.sh"

    cat > "${ROOTFS}/etc/systemd/system/first-boot-config.service" <<EOF
[Unit]
Description=Initialize router config on first boot
After=local-fs.target
Before=router-config.service
ConditionPathExists=!/config/active/config.json

[Service]
Type=oneshot
ExecStart=/usr/local/bin/first-boot-config.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

    chroot "${ROOTFS}" systemctl enable first-boot-config.service
}

# ---- Step 7: Install extra packages if specified ----
install_extras() {
    if [[ -n "${EXTRA_PACKAGES}" ]]; then
        log "Installing extra packages: ${EXTRA_PACKAGES}"
        local pkgs
        pkgs=$(echo "${EXTRA_PACKAGES}" | tr ',' ' ')
        chroot "${ROOTFS}" apt-get update -qq
        chroot "${ROOTFS}" apt-get install -y -qq ${pkgs}
        chroot "${ROOTFS}" apt-get clean
    fi
}

# ---- Step 8: Build squashfs + ISO ----
build_iso() {
    log "Building ISO image"

    # Unmount virtual filesystems
    umount_rootfs

    # Create ISO directory structure
    mkdir -p "${ISO_DIR}"/{boot/grub,casper,EFI/boot,.disk}

    # Create squashfs
    log "Creating squashfs filesystem (this takes a while)..."
    mksquashfs "${ROOTFS}" "${ISO_DIR}/casper/filesystem.squashfs" \
        -comp zstd -Xcompression-level 19 -b 1M \
        -e "${ROOTFS}/boot" \
        -no-duplicates -no-recovery

    # Copy kernel and initrd
    cp "${ROOTFS}"/boot/vmlinuz-* "${ISO_DIR}/casper/vmlinuz"
    cp "${ROOTFS}"/boot/initrd.img-* "${ISO_DIR}/casper/initrd"

    # GRUB config for BIOS + EFI
    cat > "${ISO_DIR}/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0

menuentry "${DISTRO_NAME} v${DISTRO_VERSION}" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "${DISTRO_NAME} v${DISTRO_VERSION} (Recovery)" {
    linux /casper/vmlinuz boot=casper single ---
    initrd /casper/initrd
}

menuentry "${DISTRO_NAME} - Install to Disk" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}

menuentry "Memory Test (memtest86+)" {
    linux /casper/vmlinuz memtest ---
}
EOF

    # Disk info
    echo "${DISTRO_NAME} v${DISTRO_VERSION}" > "${ISO_DIR}/.disk/info"
    echo "full-iso" > "${ISO_DIR}/.disk/cd_type"

    # Filesystem size
    printf $(du -sx --block-size=1 "${ROOTFS}" | cut -f1) > "${ISO_DIR}/casper/filesystem.size"

    # Create EFI boot image
    log "Creating EFI boot image"
    dd if=/dev/zero of="${ISO_DIR}/boot/grub/efi.img" bs=1M count=10
    mkfs.vfat "${ISO_DIR}/boot/grub/efi.img"
    mmd -i "${ISO_DIR}/boot/grub/efi.img" EFI EFI/boot
    mcopy -i "${ISO_DIR}/boot/grub/efi.img" \
        "${ROOTFS}/usr/lib/grub/x86_64-efi/monolithic/grubx64.efi" \
        "::EFI/boot/bootx64.efi" 2>/dev/null || {
        # Fallback: use grub-mkimage
        grub-mkstandalone \
            --format=x86_64-efi \
            --output="${BUILD_DIR}/bootx64.efi" \
            --locales="" \
            --fonts="" \
            "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg"
        mcopy -i "${ISO_DIR}/boot/grub/efi.img" \
            "${BUILD_DIR}/bootx64.efi" "::EFI/boot/bootx64.efi"
    }

    # Create BIOS boot image
    grub-mkstandalone \
        --format=i386-pc \
        --output="${BUILD_DIR}/core.img" \
        --install-modules="linux normal iso9660 biosdisk memdisk search tar ls" \
        --modules="linux normal iso9660 biosdisk search" \
        --locales="" \
        --fonts="" \
        "boot/grub/grub.cfg=${ISO_DIR}/boot/grub/grub.cfg"

    # Combine with cdboot.img for BIOS
    cat /usr/lib/grub/i386-pc/cdboot.img "${BUILD_DIR}/core.img" > \
        "${ISO_DIR}/boot/grub/bios.img"

    # Build the ISO
    log "Creating ISO: ${ISO_FILENAME}"
    mkdir -p "${OUTPUT_DIR}"

    xorriso \
        -as mkisofs \
        -iso-level 3 \
        -full-iso9660-filenames \
        -volid "${SAFE_NAME^^}" \
        -output "${OUTPUT_DIR}/${ISO_FILENAME}" \
        -eltorito-boot boot/grub/bios.img \
            -no-emul-boot \
            -boot-load-size 4 \
            -boot-info-table \
            --eltorito-catalog boot/grub/boot.cat \
        --grub2-boot-info \
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img \
        -eltorito-alt-boot \
            -e boot/grub/efi.img \
            -no-emul-boot \
        -append_partition 2 0xef "${ISO_DIR}/boot/grub/efi.img" \
        -graft-points \
            "${ISO_DIR}"

    echo ""
    log "ISO created: ${OUTPUT_DIR}/${ISO_FILENAME}"
    ls -lh "${OUTPUT_DIR}/${ISO_FILENAME}"
}

# ---- Step 9: Optionally build VM image (qcow2) ----
build_vm_image() {
    if [[ "${BUILD_VM_IMAGE}" != "true" ]]; then
        return
    fi

    log "Building qcow2 VM image"

    local QCOW2_FILE="${OUTPUT_DIR}/${SAFE_NAME}-${DISTRO_VERSION}-${ARCH}.qcow2"
    local DISK_SIZE="4G"
    local LOOP_DEV=""

    # Create raw disk image
    qemu-img create -f raw "${BUILD_DIR}/disk.raw" "${DISK_SIZE}"

    # Partition: 512M EFI + 256M config + rest rootfs
    parted -s "${BUILD_DIR}/disk.raw" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 esp on \
        mkpart CONFIG ext4 513MiB 769MiB \
        mkpart ROOTFS ext4 769MiB 100%

    # Setup loop device
    LOOP_DEV=$(losetup --find --show --partscan "${BUILD_DIR}/disk.raw")

    # Format partitions
    mkfs.vfat -F32 -n "EFI" "${LOOP_DEV}p1"
    mkfs.ext4 -L "CONFIG" "${LOOP_DEV}p2"
    mkfs.ext4 -L "ROOTFS" "${LOOP_DEV}p3"

    # Mount and copy rootfs
    mkdir -p "${BUILD_DIR}/mnt"
    mount "${LOOP_DEV}p3" "${BUILD_DIR}/mnt"
    mkdir -p "${BUILD_DIR}/mnt/boot/efi" "${BUILD_DIR}/mnt/config"
    mount "${LOOP_DEV}p1" "${BUILD_DIR}/mnt/boot/efi"
    mount "${LOOP_DEV}p2" "${BUILD_DIR}/mnt/config"

    # Copy rootfs
    rsync -a "${ROOTFS}/" "${BUILD_DIR}/mnt/"

    # Install GRUB in the image
    mount --bind /dev "${BUILD_DIR}/mnt/dev"
    mount --bind /proc "${BUILD_DIR}/mnt/proc"
    mount --bind /sys "${BUILD_DIR}/mnt/sys"

    # Generate fstab
    cat > "${BUILD_DIR}/mnt/etc/fstab" <<EOF
LABEL=ROOTFS  /         ext4  defaults,noatime     0  1
LABEL=EFI     /boot/efi vfat  umask=0077           0  1
LABEL=CONFIG  /config   ext4  defaults,noatime     0  2
EOF

    chroot "${BUILD_DIR}/mnt" grub-install --target=x86_64-efi \
        --efi-directory=/boot/efi --no-nvram --removable 2>/dev/null || true
    chroot "${BUILD_DIR}/mnt" update-grub 2>/dev/null || true

    # Cleanup
    umount "${BUILD_DIR}/mnt/sys" 2>/dev/null || true
    umount "${BUILD_DIR}/mnt/proc" 2>/dev/null || true
    umount "${BUILD_DIR}/mnt/dev" 2>/dev/null || true
    umount "${BUILD_DIR}/mnt/config" 2>/dev/null || true
    umount "${BUILD_DIR}/mnt/boot/efi" 2>/dev/null || true
    umount "${BUILD_DIR}/mnt" 2>/dev/null || true
    losetup -d "${LOOP_DEV}"

    # Convert to qcow2
    qemu-img convert -f raw -O qcow2 -c "${BUILD_DIR}/disk.raw" "${QCOW2_FILE}"

    log "VM image created: ${QCOW2_FILE}"
    ls -lh "${QCOW2_FILE}"
}

# ---- Cleanup helpers ----
umount_rootfs() {
    for mp in "${ROOTFS}/dev/pts" "${ROOTFS}/dev" "${ROOTFS}/proc" "${ROOTFS}/sys"; do
        umount "${mp}" 2>/dev/null || true
    done
}

cleanup() {
    if [[ "${CLEANUP}" == "true" ]]; then
        log "Cleaning up build directory"
        umount_rootfs
        rm -rf "${BUILD_DIR}"
    else
        log "Build directory preserved at: ${BUILD_DIR}"
    fi
}

trap cleanup EXIT

# ---- Main ----
main() {
    echo "╔══════════════════════════════════════════════════╗"
    echo "║         ${DISTRO_NAME} ISO Builder               ║"
    echo "║         Version: ${DISTRO_VERSION}               ║"
    echo "║         Arch: ${ARCH}                            ║"
    echo "║         Base: Ubuntu ${UBUNTU_RELEASE}           ║"
    echo "╚══════════════════════════════════════════════════╝"
    echo ""

    check_root
    install_build_deps
    bootstrap_rootfs
    configure_rootfs
    install_config_system
    harden_system
    setup_users
    setup_config_partition
    install_extras
    build_iso
    build_vm_image

    echo ""
    echo "╔══════════════════════════════════════════════════╗"
    echo "║              BUILD COMPLETE!                     ║"
    echo "╠══════════════════════════════════════════════════╣"
    echo "║  ISO: ${OUTPUT_DIR}/${ISO_FILENAME}"
    if [[ "${BUILD_VM_IMAGE}" == "true" ]]; then
    echo "║  VM:  ${OUTPUT_DIR}/${SAFE_NAME}-${DISTRO_VERSION}-${ARCH}.qcow2"
    fi
    echo "║                                                  ║"
    echo "║  Default login:  admin / admin                   ║"
    echo "║  Root login:     root / router                   ║"
    echo "║                                                  ║"
    echo "║  CHANGE PASSWORDS IMMEDIATELY!                   ║"
    echo "╚══════════════════════════════════════════════════╝"
}

main "$@"
