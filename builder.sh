#!/usr/bin/env bash

# substituteAll interface
runtimeScript=@runtimeScript@
zip=@zip@
zstd=@zstd@
proot=@proot@
bubblewrap=@bubblewrap@
nix=@nix@
busybox=@busybox@
caBundleZstd=@caBundleZstd@
storeTar=@storeTar@
bundledExe=@bundledExe@

mkdir -p $out/bin
cp $runtimeScript $out/bin/nix-portable.zip
chmod +w $out/bin/nix-portable.zip

# Local file header
sizeA=$(printf "%08x" `stat -c "%s" $out/bin/nix-portable.zip` | tac -rs ..)
echo 504b 0304 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
echo 0000 0000 0000 0000 0000 0200 0000 4242 | xxd -r -p >> $out/bin/nix-portable.zip

# Central directory file header
sizeB=$(printf "%08x" `stat -c "%s" $out/bin/nix-portable.zip` | tac -rs ..)
echo 504b 0102 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
echo 0000 0000 0000 0000 0000 0000 0200 0000 | xxd -r -p >> $out/bin/nix-portable.zip
echo 0000 0000 0000 0000 0000 $sizeA 4242 | xxd -r -p >> $out/bin/nix-portable.zip

# End of central directory record
echo 504b 0506 0000 0000 0000 0100 3000 0000 | xxd -r -p >> $out/bin/nix-portable.zip
echo $sizeB 0000 0000 0000 0000 0000 0000 | xxd -r -p >> $out/bin/nix-portable.zip

unzip -vl $out/bin/nix-portable.zip

zip="$zip/bin/zip -0"

$zip $out/bin/nix-portable.zip $busybox/bin/busybox

# we cannot unzip busybox, so we need offset and size
# locate the first 1000 bytes of busybox in the zip archive
busyboxOffset=$(
  cat $out/bin/nix-portable.zip | xxd -p -c0 |
  grep -bo -m1 $(head -c1000 $busybox/bin/busybox | xxd -p -c0) |
  cut -d: -f1
)
# hex to bin
busyboxOffset=$((busyboxOffset / 2))
busyboxSize=$(stat -c %s busybox/bin/busybox)
sed -i "0,/@busyboxOffset@/s//$(printf "%-15s" $busyboxOffset)/; \
  0,/@busyboxSize@/s//$(printf "%-13s" $busyboxSize)/" $out/bin/nix-portable.zip

$zip $out/bin/nix-portable.zip $bubblewrap/bin/bwrap
$zip $out/bin/nix-portable.zip $nix/bin/nix
$zip $out/bin/nix-portable.zip $proot/bin/proot
$zip $out/bin/nix-portable.zip $zstd/bin/zstd
$zip $out/bin/nix-portable.zip $storeTar/tar
$zip $out/bin/nix-portable.zip $caBundleZstd

# create fingerprint
fp=$(sha256sum $out/bin/nix-portable.zip | head -c64)
sed -i "0,/_FINGERPRINT_PLACEHOLDER_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/s//$fp/" $out/bin/nix-portable.zip

if [ "$bundledExe" == "" ]; then
  target="$out/bin/nix-portable"
else
  target="$out/bin/$(basename "$bundledExe")"
fi
mv $out/bin/nix-portable.zip "$target"
chmod +x "$target"
