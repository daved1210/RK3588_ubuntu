#!/bin/bash

set -eE 
trap 'echo Error: in $0 on line $LINENO' ERR

# 清理挂载和循环设备的函数
cleanup_loopdev() {
    local loop="$1"

    sync --file-system
    sync

    sleep 1

    if [ -b "${loop}" ]; then
        for part in "${loop}"p*; do
            if mnt=$(findmnt -n -o target -S "$part"); then
                umount "${mnt}"
            fi
        done
        losetup -d "${loop}"
    fi
}

# 等待循环设备准备就绪
wait_loopdev() {
    local loop="$1"
    local seconds="$2"

    until test $((seconds--)) -eq 0 -o -b "${loop}"; do sleep 1; done

    ((++seconds))

    ls -l "${loop}" &> /dev/null
}

# 必须以 root 权限运行
if [ "$(id -u)" -ne 0 ]; then 
    echo "Please run as root"
    exit 1
fi

# 检查输入参数
if [ -z "$1" ]; then
    echo "Usage: $0 filename.rootfs.tar"
    exit 1
fi

rootfs="$(readlink -f "$1")"
if [[ "$(basename "${rootfs}")" != *".rootfs.tar" || ! -e "${rootfs}" ]]; then
    echo "Error: $(basename "${rootfs}") must be a rootfs tarfile"
    exit 1
fi

# 切换到工作目录
cd "$(dirname -- "$(readlink -f -- "$0")")" && cd ..
mkdir -p images build && cd build

if [[ -z ${BOARD} ]]; then
    echo "Error: BOARD is not set"
    exit 1
fi

# 1. 创建空的磁盘镜像文件
img="../images/$(basename "${rootfs}" .rootfs.tar)${KVER}.img"
size="$(( $(wc -c < "${rootfs}" ) / 1024 / 1024 ))"
truncate -s "$(( size + 2048 ))M" "${img}"

# 2. 创建循环设备 (Loop Device)
loop="$(losetup -f)"
losetup -P "${loop}" "${img}"
disk="${loop}"

# 注册 EXIT 信号，确保脚本出错时能自动卸载 loop 设备
trap 'cleanup_loopdev ${loop}' EXIT

# 3. 准备挂载点
mount_point=/tmp/mnt
umount "${disk}"* 2> /dev/null || true
umount ${mount_point}/* 2> /dev/null || true
mkdir -p ${mount_point}

# 4. 磁盘分区逻辑 (针对 Server 或 Desktop 版本)
if [ -z "${img##*server*}" ]; then
    # Server 版分区逻辑
    dd if=/dev/zero of="${disk}" count=4096 bs=512
    parted --script "${disk}" \
    mklabel gpt \
    mkpart primary fat32 16MiB 20MiB \
    mkpart primary ext4 20MiB 100%

    {
        echo "t"
        echo "1"
        echo "EBD0A0A2-B9E5-4433-87C0-68B6B72699C7"
        echo "t"
        echo "2"
        echo "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        echo "w"
    } | fdisk "${disk}" &> /dev/null || true

    partprobe "${disk}"
    partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"

    sleep 1
    wait_loopdev "${disk}${partition_char}2" 60
    sleep 1
    wait_loopdev "${disk}${partition_char}1" 60
    sleep 1

    boot_uuid=$(uuidgen | head -c8)
    root_uuid=$(uuidgen)

    mkfs.vfat -i "${boot_uuid}" -F32 -n CIDATA "${disk}${partition_char}1"
    dd if=/dev/zero of="${disk}${partition_char}2" bs=1KB count=10 > /dev/null
    mkfs.ext4 -U "${root_uuid}" -L cloudimg-rootfs "${disk}${partition_char}2"

    mkdir -p ${mount_point}/{system-boot,writable} 
    mount "${disk}${partition_char}1" ${mount_point}/system-boot
    mount "${disk}${partition_char}2" ${mount_point}/writable

    cp ../overlay/boot/firmware/{meta-data,user-data,network-config} ${mount_point}/system-boot
else
    # Desktop 版分区逻辑 (你的 Orange Pi 5B 应该走这里)
    dd if=/dev/zero of="${disk}" count=4096 bs=512
    parted --script "${disk}" \
    mklabel gpt \
    mkpart primary ext4 16MiB 100%

    {
        echo "t"
        echo "1"
        echo "C12A7328-F81F-11D2-BA4B-00A0C93EC93B"
        echo "w"
    } | fdisk "${disk}" &> /dev/null || true

    partprobe "${disk}"
    partition_char="$(if [[ ${disk: -1} == [0-9] ]]; then echo p; fi)"

    sleep 1
    wait_loopdev "${disk}${partition_char}1" 60 || {
        echo "Failure to create ${disk}${partition_char}1 in time"
        exit 1
    }

    sleep 1
    root_uuid=$(uuidgen)
    dd if=/dev/zero of="${disk}${partition_char}1" bs=1KB count=10 > /dev/null
    mkfs.ext4 -U "${root_uuid}" -L desktop-rootfs "${disk}${partition_char}1"

    mkdir -p ${mount_point}/writable
    mount "${disk}${partition_char}1" ${mount_point}/writable
fi

# 5. 将编译好的 RootFS 压缩包解压到镜像分区中
echo "Extracting rootfs to image..."
tar -xpf "${rootfs}" -C ${mount_point}/writable

# ========================================================================
# 🛡️ 新增：注入 Oibaf PPA GPG 公钥逻辑
# 解决在 chroot 环境下因为缺少签名而无法拉取驱动包的问题
# ========================================================================
echo "🛡️  Injecting Oibaf PPA GPG keys for full-performance GPU drivers..."
# 先尝试更新（即便报错也没关系），确保能装上 gnupg
chroot ${mount_point}/writable /bin/bash -c "apt-get update || true"
chroot ${mount_point}/writable /bin/bash -c "apt-get install -y gnupg || true"
# 导入公钥
chroot ${mount_point}/writable /bin/bash -c "apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 957D2708A03A4626 93F4D583494746C8"
# ========================================================================

# 6. 配置 fstab (挂载点信息)
echo "# <file system>     <mount point>  <type>  <options>   <dump>  <fsck>" > ${mount_point}/writable/etc/fstab
echo "UUID=${root_uuid,,} /               ext4    defaults,x-systemd.growfs    0       1" >> ${mount_point}/writable/etc/fstab

# 7. 写入 Bootloader (引导程序)
if [ -f "${mount_point}/writable/usr/lib/u-boot/u-boot-rockchip.bin" ]; then
    dd if="${mount_point}/writable/usr/lib/u-boot/u-boot-rockchip.bin" of="${loop}" seek=1 bs=32k conv=fsync
else
    dd if="${mount_point}/writable/usr/lib/u-boot/idbloader.img" of="${loop}" seek=64 conv=notrunc
    dd if="${mount_point}/writable/usr/lib/u-boot/u-boot.itb" of="${loop}" seek=16384 conv=notrunc
fi

# 8. 执行板级钩子函数
if [[ $(type -t build_image_hook__"${BOARD}") == function ]]; then
    build_image_hook__"${BOARD}"
fi 

# 9. 更新 U-Boot 配置
chroot ${mount_point}/writable/ u-boot-update

sync --file-system
sync

# 10. 卸载分区
umount "${disk}${partition_char}1"
umount "${disk}${partition_char}2" 2> /dev/null || true

# 11. 释放循环设备
losetup -d "${loop}"

# 12. 清理陷阱
trap '' EXIT

# 13. 最终镜像压缩 (生成 .img.xz)
echo -e "\nCompressing $(basename "${img}.xz")\n"
xz -6 --force --keep --quiet --threads=0 "${img}"
rm -f "${img}"
cd ../images && sha256sum "$(basename "${img}.xz")" > "$(basename "${img}.xz.sha256")"

echo "Build complete! Your image is ready in the images/ directory."
