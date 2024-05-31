#!/bin/bash

BASEDIR=$(dirname $0)

GNRL="NVIDIA-Linux-x86_64-535.129.03"
VGPU="NVIDIA-Linux-x86_64-535.129.03-vgpu-kvm"
GRID="NVIDIA-Linux-x86_64-535.129.03-grid"
WSYS="NVIDIA-Windows-x86_64-537.70"

REPACK=true
SWITCH_GRID_TO_GNRL=false


VER_VGPU=`echo ${VGPU} | awk -F- '{print $4}'`
VER_GRID=`echo ${GRID} | awk -F- '{print $4}'`

CP="cp -a"

case `stat -f --format=%T .` in
    btrfs | xfs)
        CP="$CP --reflink"
        ;;
esac


DO_MRGD=true

while [ $# -gt 0 -a "${1:0:2}" = "--" ]
do
    case "$1" in
        --repack)
            shift
            REPACK=true
            ;;
        *)
            echo "Unknown option $1"
            shift
            ;;
    esac
done

case "$1" in
    general-merge)
        DO_VGPU=true
        DO_GRID=true
        DO_MRGD=true
        if $SWITCH_GRID_TO_GNRL; then
            echo "WARNING: did not find general driver, trying to create it from grid one"
            GNRL="${GRID/-grid}"
        else
            GRID="${GNRL}"
        fi
        MRGD="${GNRL}-merged-vgpu-kvm"
        SOURCE="${MRGD}"
        TARGET="${MRGD}-patched"
        ;;
    *)
        echo "Usage: $0 [options] <general-merge>"
        exit 1
        ;;
esac

VER_TARGET=`echo ${SOURCE} | awk -F- '{print $4}'`
VER_BLOB=`echo ${VGPU} | awk -F- '{print $4}'`

die() {
    echo "$@"
    exit 1
}

extract() {
    TDIR="${2}"
    if [ -z "${TDIR}" ]; then
        TDIR="${1%.run}"
    fi
    if [ -e ${1} ]; then
        $REPACK && sh ${1} --lsm > ${TARGET}.lsm
    fi
    if [ -d ${TDIR} ]; then
        echo "WARNING: skipping extract of ${1} as it seems already extracted in ${TDIR}"
        return 0
    fi
    [ -e ${1} ] || die "package ${1} not found"
    sh ${1} --extract-only --target ${TDIR}
    echo >> ${TDIR}/kernel/nvidia/nvidia.Kbuild
    chmod -R u+w ${TDIR}
}


$DO_VGPU && extract ${VGPU}.run
$DO_GRID && {
    if $SWITCH_GRID_TO_GNRL; then
      if [ -d ${GNRL} ]; then
        echo "WARNING: skipping switch from grid to general as it seems present in ${GNRL}"
      else
        extract ${GRID}.run ${GNRL}
        applypatch ${GNRL} vgpu-kvm-merge-grid-scripts.patch -R
        GRID=${GNRL}
        grep ' MODULE:vgpu$\|kernel/nvidia/nv-vgpu-vmbus' ${GRID}/.manifest | awk -F' ' '{print $1}' | while read i
        do
            rm -f ${GRID}/$i
        done
        sed -e '/ MODULE:vgpu$/ d' -e '/kernel\/nvidia\/nv-vgpu-vmbus/ d'  -i ${GRID}/.manifest
        sed -e '/nvidia\/nv-vgpu-vmbus.c/ d' -i ${GRID}/kernel/nvidia/nvidia-sources.Kbuild
        sed -e '/^[ \t]*GRID_BUILD=1/ d' -i ${GRID}/kernel/conftest.sh
      fi
    else
        extract ${GRID}.run
    fi
}

if $DO_MRGD; then
    echo "about to create merged driver"
    rm -rf ${SOURCE}
    mkdir ${SOURCE}
    $CP ${VGPU}/. ${SOURCE}
    rm ${SOURCE}/libnvidia-ml.so.${VER_VGPU}
    $CP ${GRID}/. ${SOURCE}
    rm -rf ${SOURCE}/firmware
    for i in LICENSE kernel/nvidia/nvidia-sources.Kbuild init-scripts/{post-install,pre-uninstall} nvidia-bug-report.sh kernel/nvidia/nv-kernel.o_binary firmware
    do
        $CP -f ${VGPU}/$i ${SOURCE}/$i
    done
    sed -e '/^# VGX_KVM_BUILD/aVGX_KVM_BUILD=1' -i ${SOURCE}/kernel/conftest.sh
    sed -e 's/^\(nvidia .*nvidia-drm.*\)/\1 nvidia-vgpu-vfio/' -i ${SOURCE}/.manifest
    diff -u ${VGPU}/.manifest ${GRID}/.manifest \
    | grep -B 1 '^-.* MODULE:\(vgpu\|installer\)$' | grep -v '^--$' \
    | sed -e '/^ / s:/:\\/:g' -e 's:^ \(.*\):/\1/ a \\:' -e 's:^-\(.*\):\1\\:' | head -c -2 \
    | sed -e ':append' -e '/\\\n\// b found' -e N -e 'b append' -e ':found' -e 's:\\\n/:\n/:' \
    > manifest-merge.sed
    echo "merging .manifest file"
    sed -f manifest-merge.sed -i ${SOURCE}/.manifest
    rm manifest-merge.sed
    [ -e ${SOURCE}/nvidia-gridd ] && applypatch ${SOURCE} vgpu-kvm-merge-grid-scripts.patch
    # applypatch ${SOURCE} disable-nvidia-blob-version-check.patch
fi

rm -rf ${TARGET}
$CP ${SOURCE} ${TARGET}

if $DO_GNRL; then
    VER_BLOB=${VER_TARGET}
    grep -q '^GRID_BUILD=1' ${TARGET}/kernel/conftest.sh || sed -e '/^# GRID_BUILD /aGRID_BUILD=1' -i ${TARGET}/kernel/conftest.sh
fi

# $DO_VGPU && applypatch ${TARGET} vgpu-kvm-optional-vgpu-v2.patch

# $DO_MRGD && {
#     sed -e '/^NVIDIA_CFLAGS += .*BIT_MACROS$/aNVIDIA_CFLAGS += -DVUP_MERGED_DRIVER=1' -i ${TARGET}/kernel/nvidia/nvidia.Kbuild
#     blobpatch ${TARGET}/libnvidia-ml.so.${VER_TARGET} "$BASEDIR/patches/libnvidia-ml.so.${VER_TARGET%.*}.diff" || exit 1
# }


if $REPACK; then
    REPACK_OPTS="${REPACK_OPTS:---silent}"
    [ -e ${TARGET}.lsm ] && REPACK_OPTS="${REPACK_OPTS} --lsm ${TARGET}.lsm"
    [ -e ${TARGET}/pkg-history.txt ] && REPACK_OPTS="${REPACK_OPTS} --pkg-history ${TARGET}/pkg-history.txt"
    echo "about to create ${TARGET}.run file"
    ./${TARGET}/makeself.sh ${REPACK_OPTS} --version-string "${VER_TARGET}" --target-os Linux --target-arch x86_64 \
        ${TARGET} ${TARGET}.run \
        "NVIDIA Accelerated Graphics Driver for Linux-x86_64 ${TARGET#NVIDIA-Linux-x86_64-}" \
        ./nvidia-installer
    rm -f ${TARGET}.lsm
    echo "done"
fi

