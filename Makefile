# SPDX-License-Identifier: Unlicence
#
# For the contents of this file, these terms apply:
#
# This is free and unencumbered software released into the public domain.
# 
# Anyone is free to copy, modify, publish, use, compile, sell, or
# distribute this software, either in source code form or as a compiled
# binary, for any purpose, commercial or non-commercial, and by any
# means.
#
# In jurisdictions that recognize copyright laws, the author or authors
# of this software dedicate any and all copyright interest in the
# software to the public domain. We make this dedication for the benefit
# of the public at large and to the detriment of our heirs and
# successors. We intend this dedication to be an overt act of
# relinquishment in perpetuity of all present and future rights to this
# software under copyright law.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
# IN NO EVENT SHALL THE AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
# For more information, please refer to <https://unlicense.org/>

.NOTPARALLEL: checkout modifications image
.PHONY: build wipe pi-gen checkout modifications image help understand
.DEFAULT_GOAL := understand

# Configurables
FIRMWARE_PARTITION_SIZE_MB ?= 160
SWAP_FILE_MAX_SIZE_MB ?= 192
USER_ACCOUNT_USERNAME ?= cube
USER_ACCOUNT_PASSWORD ?= cube
SYSTEM_HOSTNAME ?= cube
PIGEN_TARGET_GIT_STATE ?= 358f9785089fa9fce397b7c36de2d90a9ae9a50e
PIGEN_BUILD_CONTAINER_NAME ?= cube1_raspberryos_builder

# Non-configurables
PI_GEN := $(shell pwd)/pi-gen
ARTIFACTS := $(shell pwd)/artifacts-from-build
PIGEN_BUILD_CONTAINER_STATUS := $(shell docker ps -a -f name=$(PIGEN_BUILD_CONTAINER_NAME) | wc -l )
PIGEN_CURRENT_GIT_STATE = $(shell git -C $(PI_GEN) rev-parse HEAD)

define PACKAGES_TO_REMOVE_FROM_ANY_STAGE
linux-image-rpi-v7
linux-headers-rpi-v6
linux-headers-rpi-v7
linux-headers-rpi-v8
build-essential
mkvtoolnix
rpicam-apps-lite
wwpasupplicant
wireless-tools
firmware-atheros
firmware-brcm80211
firmware-libertas
firmware-realtek
firmware-mediatek
firmware-marvell-prestera-
fbset
strace
build-essential
manpages-dev
gdb
pkg-config
v4l-utils
python3-libgpiod
python3-gpiozero
python3-rpi-lgpio
python3-spidev
python3-smbus2
libmtp-runtime
ntfs-3g
pciutils
kms++-utils
pi-bluetooth
bluez-firmware
bluez
rpi-keyboard-config
rpi-keyboard-fw-update
rpi-usb-gadget
rpi-connect-lite
endef

PKG_MANIFESTS = $(shell find $(PI_GEN)/stage[0-2] -type f -regex '.*[0-9].*packages.*'|sort)
PKG_REMOVALS := $(shell grep -Pzo '(?s)(?<=define PACKAGES_TO_REMOVE_FROM_ANY_STAGE).*?(?=endef)' Makefile|tr '\n' ' ')

##  * make build - Do everything needed for producing a build from scratch.
build: wipe pi-gen .WAIT modifications .WAIT image

##  * make wipe - Wipes build artifacts folder if present
wipe:
	@ if test -d $(ARTIFACTS); then \
		echo "# Found build artifacts directory, wiping it..." \
		&& rm -rf $(ARTIFACTS) ; \
	fi

##  * make pi-gen - Set the pi-gen submodule to desired state and delete docker build container if found
pi-gen:
	# Ensuring pi-gen is in desired state
	@ if [ -f $(PI_GEN)/build-docker.sh ]; then \
		git -C $(PI_GEN) reset --hard \
		&& git -C $(PI_GEN) clean -xfd \
		&& git -C $(PI_GEN) pull origin master; \
	else \
		git submodule update --init ; \
	fi

	@if [ "$(PIGEN_CURRENT_GIT_STATE)" != "$(PIGEN_TARGET_GIT_STATE)" ]; then \
		git -C $(PI_GEN) checkout $(PIGEN_TARGET_GIT_STATE) ; \
	fi

	@ if test $(PIGEN_BUILD_CONTAINER_STATUS) -gt 1; then \
		echo 'Wiping docker container "$(PIGEN_BUILD_CONTAINER_NAME)" from earlier run' \
		&& docker rm -v $(PIGEN_BUILD_CONTAINER_NAME) ; \
	fi

##  * make modifications - Apply customizations to clean/fresh upstream pi-gen
modifications:
	# Setting boot partition size to $(FIRMWARE_PARTITION_SIZE_MB)M
	@sed -i -e 's/^BOOT_SIZE="\$$((.*$$/BOOT_SIZE="\$$(($(FIRMWARE_PARTITION_SIZE_MB) * 1024 * 1024))"/g' $(PI_GEN)/export-image/prerun.sh

	# Removing packages from build:
	@ for PKG_NAME in $(PKG_REMOVALS); do \
		echo "  * $$PKG_NAME"; \
		for PKG_MANIFEST in $(PKG_MANIFESTS); do \
			sed -i "s/$$PKG_NAME//g" $$PKG_MANIFEST; \
		done; \
	done

	# Doing package manifest file cleanup...
	@ for PKG_MANIFEST in $(PKG_MANIFESTS); do \
		cat $$PKG_MANIFEST \
			| sed -E 's/((^\s+)|(\s+$$))//g' \
			| sed -zE 's/\n+/\n/g' \
			| sed -E 's/[[:blank:]]+/ /g' \
			| dd of="$$PKG_MANIFEST" status=none ; \
	done; \

	# Adding packages to build
	@ echo "  * busybox" && echo "busybox" >> $(PI_GEN)/stage0/02-firmware/01-packages
	@ echo "  * zstd" && echo "zstd" >> $(PI_GEN)/stage0/02-firmware/01-packages
	@ echo "  * lrzsz" && echo "lrzsz" >> $(PI_GEN)/stage2/01-sys-tweaks/00-packages
	@ echo "  * screen" && echo "screen" >> $(PI_GEN)/stage2/01-sys-tweaks/00-packages

	# Fixing and adding /boot/firmware/ files:
	@ for BOOTFS_FILE in userconf.txt config.txt config-fhcube-computemodule.txt config-fhcube-common.txt; do \
		if grep -q "files/$$BOOTFS_FILE" $(PI_GEN)/stage1/00-boot-files/00-run.sh; then /bin/true ; else \
			echo -n "install -m 644 files/$$BOOTFS_FILE" >> $(PI_GEN)/stage1/00-boot-files/00-run.sh \
			&& echo ' "$${ROOTFS_DIR}/boot/firmware/"' >> $(PI_GEN)/stage1/00-boot-files/00-run.sh ;\
		fi ; \
		if test -f cube1-board-support-files/$$BOOTFS_FILE ; then \
			echo "  * $$BOOTFS_FILE" \
			&& cp cube1-board-support-files/$$BOOTFS_FILE $(PI_GEN)/stage1/00-boot-files/files/$$BOOTFS_FILE; \
		fi \
	; done
	@ echo "  * userconf.txt"
	@ echo -n "$(USER_ACCOUNT_USERNAME):" > $(PI_GEN)/stage1/00-boot-files/files/userconf.txt
	@ echo "$(USER_ACCOUNT_PASSWORD)" | openssl passwd -6 -stdin >> $(PI_GEN)/stage1/00-boot-files/files/userconf.txt

	@ if grep -q "APT::Install-Recommends" $(PI_GEN)/stage0/00-configure-apt/00-run.sh; then \
	echo "# APT already configured to not install recommended packages, skipping..."; else \
	echo "# Configuring APT to not install recommended packages" \
	&& sed -i '/raspberrypi-archive-keyring.*$$/a echo \x27APT::Install-Recommends "false";\x27 > "$$\{ROOTFS_DIR\}/etc/apt/apt.conf.d/99norecommends"' $(PI_GEN)/stage0/00-configure-apt/00-run.sh ; fi

	@ if test -e $(PI_GEN)/stage2/03-accept-mathematica-eula; then \
	rm -r $(PI_GEN)/stage2/03-accept-mathematica-eula; fi

	@ if grep -q "console=serial0,115200" $(PI_GEN)/stage1/00-boot-files/files/cmdline.txt; then \
	echo "# Disabling serial console in cmdline.txt" \
	&& sed -i 's/console=serial0,115200 //' $(PI_GEN)/stage1/00-boot-files/files/cmdline.txt; else \
	echo "# Serial console already disabled in cmdline.txt, skipping..."; fi

	# Telling system to not spawn shell at tty1
	@echo 'on_chroot << EOF' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh
	@echo 'systemctl disable getty@tty1.service && systemctl mask getty@tty1.service' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh
	@echo 'EOF' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh

	# Configuring swap space
	@echo 'on_chroot << EOF' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh
	@echo 'mkdir -p /etc/rpi/swap.conf.d' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh
	@echo 'echo "[File]" > /etc/rpi/swap.conf.d/50-swap-file-max-size.conf' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh
	@echo 'echo "MaxSizeMiB=192" >> /etc/rpi/swap.conf.d/50-swap-file-max-size.conf' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh
	@echo 'EOF' >> $(PI_GEN)/stage2/01-sys-tweaks/01-run.sh

	# Mitigating issue described at https://github.com/RPi-Distro/pi-gen/issues/862
	@ wget -q -O $(PI_GEN)/stage0/files/raspberrypi.gpg https://github.com/RPi-Distro/pi-gen/raw/676ba8a7476bd5923e5b677473b11ba52b21c6bd/stage0/files/raspberrypi.gpg \
		&& echo "  * Updated local raspberrypi.gbg signing keyring"
	
	# Writing pi-gen build config file
	@ echo 'IMG_NAME="rpios-fhcube-trixie"' > $(PI_GEN)/config
	@ echo 'PI_GEN_RELEASE="Raspberry Pi OS customized for Futurehome cube-1v*-eu"' >> $(PI_GEN)/config
	@ echo 'RELEASE="trixie"' >> $(PI_GEN)/config
	@ echo 'ENABLE_SSH=1' >> $(PI_GEN)/config
	@ echo 'LOCALE_DEFAULT=C.UTF-8' >> $(PI_GEN)/config
	@ echo 'TARGET_HOSTNAME=$(SYSTEM_HOSTNAME)' >> $(PI_GEN)/config
	@ echo 'TIMEZONE_DEFAULT=Europe/Oslo' >> $(PI_GEN)/config
	@ echo 'STAGE_LIST="stage0 stage1 stage2"' >> $(PI_GEN)/config

##  * make image - Invokes the pi-gen docker build script. Will continue previously halted/crashed build. 
image:
	# Starting dockerized build process...
	cd $(PI_GEN) && CONTINUE=1 CONTAINER_NAME=$(PIGEN_BUILD_CONTAINER_NAME) ./build-docker.sh
	mkdir -p $(ARTIFACTS)
	mv $(PI_GEN)/deploy/* $(ARTIFACTS)/

##  * make help / make understand - show this help message
understand: help
help:
	@ echo "Let's build a customized Raspberry Pi OS image for Futurehome cube-1v* devices!"
	@ echo "Build tasks:"
	@ grep '##  \* make' Makefile | tr -d '#'
	@ echo ""
	@ echo "Envvar-configurable build options:"
	@ grep ' ?= ' Makefile \
		| sed -E 's/\s\?=\s/ is by default set to /g' \
		| sed 's/^/  * /' \
		| head -n -1
		