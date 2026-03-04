# Makefile for NetRouter OS
# Usage:
#   make iso              - Build ISO only
#   make vm               - Build ISO + qcow2 VM image
#   make clean            - Remove build artifacts
#   make test-vm          - Boot the qcow2 in QEMU for testing

DISTRO_NAME   ?= NetRouter OS
DISTRO_VERSION ?= 1.0.0
ARCH           ?= amd64
UBUNTU_RELEASE ?= noble
OUTPUT_DIR     ?= ./output
SAFE_NAME      := $(shell echo "$(DISTRO_NAME)" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')

.PHONY: iso vm clean test-vm test-iso help

help:
	@echo "NetRouter OS Build System"
	@echo ""
	@echo "Targets:"
	@echo "  make iso           Build bootable ISO"
	@echo "  make vm            Build ISO + qcow2 VM image"
	@echo "  make test-vm       Test VM image in QEMU"
	@echo "  make test-iso      Test ISO in QEMU"
	@echo "  make clean         Remove build output"
	@echo ""
	@echo "Variables:"
	@echo "  DISTRO_NAME=$(DISTRO_NAME)"
	@echo "  DISTRO_VERSION=$(DISTRO_VERSION)"
	@echo "  ARCH=$(ARCH)"
	@echo "  UBUNTU_RELEASE=$(UBUNTU_RELEASE)"

iso:
	sudo bash build-router-iso.sh \
		--name "$(DISTRO_NAME)" \
		--version "$(DISTRO_VERSION)" \
		--arch "$(ARCH)" \
		--ubuntu-release "$(UBUNTU_RELEASE)" \
		--output "$(OUTPUT_DIR)"

vm:
	sudo bash build-router-iso.sh \
		--name "$(DISTRO_NAME)" \
		--version "$(DISTRO_VERSION)" \
		--arch "$(ARCH)" \
		--ubuntu-release "$(UBUNTU_RELEASE)" \
		--output "$(OUTPUT_DIR)" \
		--vm-image

# Test the qcow2 image in QEMU with 4 NICs (simulating multi-interface)
test-vm:
	qemu-system-x86_64 \
		-enable-kvm \
		-m 2048 \
		-cpu host \
		-smp 2 \
		-drive file=$(OUTPUT_DIR)/$(SAFE_NAME)-$(DISTRO_VERSION)-$(ARCH).qcow2,format=qcow2 \
		-netdev user,id=wan,hostfwd=tcp::2222-:22 \
		-device virtio-net-pci,netdev=wan,mac=52:54:00:00:00:01 \
		-netdev socket,id=trunk,mcast=230.0.0.1:1234 \
		-device virtio-net-pci,netdev=trunk,mac=52:54:00:00:00:02 \
		-netdev user,id=mgmt \
		-device virtio-net-pci,netdev=mgmt,mac=52:54:00:00:00:03 \
		-netdev user,id=extra \
		-device virtio-net-pci,netdev=extra,mac=52:54:00:00:00:04 \
		-nographic \
		-serial mon:stdio

# Test the ISO in QEMU
test-iso:
	qemu-system-x86_64 \
		-enable-kvm \
		-m 2048 \
		-cpu host \
		-smp 2 \
		-cdrom $(OUTPUT_DIR)/$(SAFE_NAME)-$(DISTRO_VERSION)-$(ARCH).iso \
		-netdev user,id=wan,hostfwd=tcp::2222-:22 \
		-device virtio-net-pci,netdev=wan \
		-netdev user,id=trunk \
		-device virtio-net-pci,netdev=trunk \
		-nographic \
		-serial mon:stdio

clean:
	rm -rf $(OUTPUT_DIR)
