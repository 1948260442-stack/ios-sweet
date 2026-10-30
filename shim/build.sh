#!/bin/bash
# Build the shim and wrap it in a boot.img v2 that mirrors the stock PixelOS header.
set -euo pipefail
cd "$(dirname "$0")"
CC=${CC:-aarch64-linux-gnu-gcc}
OBJCOPY=${OBJCOPY:-aarch64-linux-gnu-objcopy}
READELF=${READELF:-aarch64-linux-gnu-readelf}
NM=${NM:-aarch64-linux-gnu-nm}
MKBOOTIMG=${MKBOOTIMG:-mkbootimg}
CFLAGS="-O2 -ffreestanding -nostdlib -fno-pic -mgeneral-regs-only -mstrict-align -fno-stack-protector -Wall -Wextra ${EXTRA_CFLAGS:-}"
mkdir -p out
for f in start.S shim.c console.c mmu.c fdt.c loader.c ufs.c; do
	$CC $CFLAGS -c $f -o out/${f%.*}.o
done
# The image runs wherever ABL puts it with no relocation pass: only the
# header's image_size (start.o, linked at 0) may be an absolute address.
abs=$($READELF -r out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o | grep -c ABS64 || true)
[ "$abs" = 0 ] || { echo "error: $abs absolute relocations in C objects" >&2; exit 1; }
$CC $CFLAGS -static -T shim.ld -Wl,--build-id=none -Wl,--no-warn-rwx-segments -Wl,-N \
	out/start.o out/shim.o out/console.o out/mmu.o out/fdt.o out/loader.o out/ufs.o -o out/shim.elf
$OBJCOPY -O binary out/shim.elf out/Image
# ABL copies the file; pad to image_size so .bss/stacks exist as zeroed bytes.
# (bash arithmetic understands 0x.., so this works with mawk as well as gawk)
size=$($NM out/shim.elf | awk '$3=="_end"{print $1}')
# nm prints 16 hex digits with leading zeros; without the 0x prefix bash would
# read them as octal. Force hex.
size=$((0x$size))
truncate -s "$size" out/Image

# Qualcomm/MIUI kernels of this generation are wrapped in a 0x14-byte container
# starting with the ASCII magic "UNCOMPRESSED_IMG". The stock and TWRP kernels
# both carry it; cepheus' ABL silently refuses to boot an unwrapped ARM64 Image
# (it just drops back to fastboot, no error). Wrapping moves our own ARM64
# header to 0x14, so its magic lands at 0x4c exactly like theirs.
if [ "${WRAP_UNCOMPRESSED_IMG:-0}" = "1" ]; then
	# Layout (verified against both the stock and the TWRP kernel blob):
	#   0x00  "UNCOMPRESSED_IMG"       16 bytes, no NUL
	#   0x10  u32 dtb_off              offset of the appended DTB, relative to 0x14
	#   0x14  ARM64 Image
	#   ..    DTB                      at 0x14 + dtb_off
	# ABL reads the DTB to find the board; a container without one is refused.
	python3 - <<'PY'
	import struct
	img = open('out/Image', 'rb').read()
	dtb = open('../dtb/boot_unpacked/dtb', 'rb').read()
	img += b'\x00' * ((-len(img)) % 4096)
	blob = b'UNCOMPRESSED_IMG' + struct.pack('<I', len(img)) + img + dtb
	open('out/Image.w', 'wb').write(blob)
	print('wrapped: image=%d dtb=%d dtb_off=%#x total=%d'
	      % (len(img), len(dtb), len(img), len(blob)))
	PY
	mv out/Image.w out/Image
fi
# Ramdisk: an xnu payload (tools/mkpayload.py) if given as $1, else an empty
# newc cpio (ABL dislikes a zero-size ramdisk on some builds) -> diagnostics.
if [ -n "${1:-}" ]; then
	cp "$1" out/ramdisk.bin
else
	(cd out && rm -rf rd && mkdir rd && cd rd && find . | cpio -o -H newc --quiet | gzip -9 > ../ramdisk.bin)
fi
# Boot image packing. Devices differ here:
#   sweet   -> header v2 with the stock DTB embedded in the boot image
#   cepheus -> header v1, no DTB (ABL supplies the board tree from dtbo.img;
#              its stock boot.img and TWRP are both v1 with dtb_size 0)
HEADER_VERSION=${HEADER_VERSION:-2}
DTB_ARG=${DTB_ARG---dtb ../dtb/boot_unpacked/dtb}
$MKBOOTIMG --header_version "$HEADER_VERSION" --kernel out/Image --ramdisk out/ramdisk.bin \
	$DTB_ARG --base 0 --kernel_offset 0x8000 --ramdisk_offset 0x1000000 \
	--tags_offset 0x100 --dtb_offset 0x1f00000 --pagesize 4096 \
	--os_version "${OS_VERSION:-17.0.0}" --os_patch_level "${OS_PATCH_LEVEL:-2035-06}" \
	--cmdline "console=null" -o out/shim-boot.img
# Host render of the console layout.
gcc -O1 -Wall -o out/host_test console.c host_test.c && ./out/host_test
ls -l out/Image out/shim-boot.img
