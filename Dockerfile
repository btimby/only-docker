ARG ARCH=
FROM ${ARCH}ubuntu:22.04

ENV IPTABLES_VERSION 1.4.21
ENV DOCKER_VERSION 24.0.7

# Enable sources for build-dep below.
RUN sed -i 's/^# deb-src /deb-src /' /etc/apt/sources.list

RUN apt-get update
RUN apt-get install -y busybox-static bc wget libc6-dev

# Build static iptables
RUN apt-get build-dep -y --no-install-recommends iptables
# This causes iptables to fail to compile... don't know why yet
RUN apt-get purge -y libnfnetlink-dev
RUN wget -O /usr/src/iptables-${IPTABLES_VERSION}.tar.bz2 http://www.netfilter.org/projects/iptables/files/iptables-${IPTABLES_VERSION}.tar.bz2
RUN cd /usr/src && \
    tar xjf iptables-${IPTABLES_VERSION}.tar.bz2 && \
    cd iptables-${IPTABLES_VERSION} && \
    ./configure --enable-static --disable-shared && \
    make -j8 CFLAGS="-static -static-libgcc" LDFLAGS="-all-static"

# Build kernel
#RUN apt-get build-dep -y --no-install-recommends linux
RUN apt-get install -y bc libelf-dev git libncurses-dev gawk flex \
    bison openssl libssl-dev dkms libelf-dev libudev-dev libpci-dev \
    libiberty-dev autoconf llvm kmod
RUN cd /usr/src && \
    git clone --depth=1 https://github.com/raspberrypi/linux && \
    cd linux && \
    make KERNEL=kernel8 bcm2711_defconfig && \
    make -j8 Image.gz modules dtbs && \
    make INSTALL_MOD_PATH=/usr/src/root modules_install firmware_install

# Taken from boot2docker
# Remove useless kernel modules, based on unclejack/debian2docker
RUN cd /usr/src/root/lib/modules && \
    rm -rf ./*/kernel/sound/* && \
    rm -rf ./*/kernel/drivers/gpu/* && \
    rm -rf ./*/kernel/drivers/infiniband/* && \
    rm -rf ./*/kernel/drivers/isdn/* && \
    rm -rf ./*/kernel/drivers/media/* && \
    rm -rf ./*/kernel/drivers/staging/lustre/* && \
    rm -rf ./*/kernel/drivers/staging/comedi/* && \
    rm -rf ./*/kernel/fs/ocfs2/* && \
    rm -rf ./*/kernel/net/bluetooth/* && \
    rm -rf ./*/kernel/net/mac80211/* && \
    rm -rf ./*/kernel/net/wireless/*

# Install docker
RUN wget -O /usr/src/docker-${DOCKER_VERSION}.tgz https://mirrors.aliyun.com/docker-ce/linux/static/stable/aarch64/docker-${DOCKER_VERSION}.tgz
RUN apt-get install -y ca-certificates
RUN mkdir -p /usr/src/root/bin && \
    tar xvzf /usr/src/docker-${DOCKER_VERSION}.tgz --strip-components=1 -C /usr/src/root/bin

# Create dhcp image
RUN /usr/src/root/bin/docker -s vfs -d --bridge none & \
    sleep 1 && \
    /usr/src/root/bin/docker pull busybox && \
    /usr/src/root/bin/docker run --name export busybox false ; \
    /usr/src/root/bin/docker export export > /usr/src/root/.dhcp.tar

# Install isolinux
RUN apt-get install -y \
    isolinux \
    xorriso

# Start assembling root
COPY assets/init /usr/src/root/
COPY assets/console-container.sh /usr/src/root/bin/
RUN cd /usr/src/root/bin && \
    cp /bin/busybox . && \
    chmod u+s busybox && \
    cp /usr/src/iptables-${IPTABLES_VERSION}/iptables/xtables-multi iptables && \
    strip --strip-all iptables && \
    for i in mount modprobe mkdir openvt sh mknod; do \
        ln -s busybox $i; \
    done && \
    cd .. && \
    mkdir -p ./etc/ssl/certs && \
    cp /etc/ssl/certs/ca-certificates.crt ./etc/ssl/certs && \
    ln -s bin sbin
RUN mkdir -p /usr/src/only-docker/boot && \
    cd /usr/src/root && \
    find | cpio -H newc -o | lzma -c > ../only-docker/boot/initrd && \
    cp /usr/src/linux-${KERNEL_VERSION}/arch/x86_64/boot/bzImage ../only-docker/boot/vmlinuz
RUN mkdir -p /usr/src/only-docker/boot/isolinux && \
    cp /usr/lib/ISOLINUX/isolinux.bin /usr/src/only-docker/boot/isolinux && \
    cp /usr/lib/syslinux/modules/bios/ldlinux.c32 /usr/src/only-docker/boot/isolinux
COPY assets/isolinux.cfg /usr/src/only-docker/boot/isolinux/
# Copied from boot2docker, thanks.
RUN cd /usr/src/only-docker && \
    xorriso \
        -publisher "Rancher Labs, Inc." \
        -as mkisofs \
        -l -J -R -V "OnlyDocker-v0.1" \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -b boot/isolinux/isolinux.bin -c boot/isolinux/boot.cat \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -o /only-docker.iso $(pwd)
