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

mkdir -p "$out"/bin
cp $runtimeScript "$out"/bin/nix-portable.zip
chmod +w "$out"/bin/nix-portable.zip

file_name=runtimeScript.sh
file_name_size_hex=$(printf "%04x" ${#file_name} | tac -rs ..)
file_name_hex=$(echo -n "$file_name" | xxd -p)

# note: zip fails to extract the file because the local file header comes after the file contents

# Local file header
local_file_header_offset_hex=$(printf "%08x" $(stat -c "%s" "$out"/bin/nix-portable.zip) | tac -rs ..)
{
  echo 50 4b 03 04 # Local file header signature
  echo 00 00 # Version needed to extract (minimum)
  echo 00 00 # General purpose bit flag
  echo 00 00 # Compression method
  echo 00 00 # File last modification time
  echo 00 00 # File last modification date
  echo 00 00 00 00 # CRC-32 of uncompressed data
  echo 00 00 00 00 # Compressed size
  echo 00 00 00 00 # Uncompressed size
  echo $file_name_size_hex # File name length (n)
  echo 00 00 # Extra field length (m)
  echo $file_name_hex # File name
  # Extra field
} | xxd -r -p >> "$out"/bin/nix-portable.zip

# Central directory file header
central_directory_file_header_offset_hex=$(printf "%08x" $(stat -c "%s" "$out"/bin/nix-portable.zip) | tac -rs ..)
{
  echo 50 4b 01 02 # Central directory file header signature
  echo 00 00 # Version made by
  echo 00 00 # Version needed to extract (minimum)
  echo 00 00 # General purpose bit flag
  echo 00 00 # Compression method
  echo 00 00 # File last modification time
  echo 00 00 # File last modification date
  echo 00 00 00 00 # CRC-32 of uncompressed data
  echo 00 00 00 00 # Compressed size
  echo 00 00 00 00 # Uncompressed size
  echo $file_name_size_hex # File name length (n)
  echo 00 00 # Extra field length (m)
  echo 00 00 # File comment length (k)
  echo 00 00 # Disk number where file starts (or 0xffff for ZIP64)
  echo 00 00 # Internal file attributes
  echo 00 00 00 00 # External file attributes
  echo "$local_file_header_offset_hex" # Relative offset of local file header
  echo $file_name_hex # File name
  # Extra field
  # File comment
} | xxd -r -p >> "$out"/bin/nix-portable.zip

# 62 -> 3e 00 00 00
central_directory_size_hex=$(printf "%08x" $((46 + ${#file_name})) | tac -rs ..)

# End of central directory record
{
  echo 50 4b 05 06 # End of central directory signature
  echo 00 00 # Number of this disk
  echo 00 00 # Disk where central directory starts
  echo 00 00 # Number of central directory records on this disk
  echo 01 00 # Total number of central directory records
  echo $central_directory_size_hex # Size of central directory (bytes)
  echo "$central_directory_file_header_offset_hex" # Offset of start of central directory, relative to start of archive
  echo 00 00 # Comment length
  # Comment
  echo 00 00 00 00 00 00 00 00 00 00 # 10 null bytes (?)
} | xxd -r -p >> "$out"/bin/nix-portable.zip

unzip -vl "$out"/bin/nix-portable.zip

zip="$zip/bin/zip -0"

$zip "$out"/bin/nix-portable.zip $busybox/bin/busybox

# we cannot unzip busybox, so we need offset and size
# locate the first 1000 bytes of busybox in the zip archive
busyboxOffset=$(
  cat "$out"/bin/nix-portable.zip | xxd -p -c0 |
  grep -bo -m1 $(head -c1000 $busybox/bin/busybox | xxd -p -c0) |
  cut -d: -f1
)
# hex to bin
busyboxOffset=$((busyboxOffset / 2))
busyboxSize=$(stat -c %s busybox/bin/busybox)
sed -i "0,/@busyboxOffset@/s//$(printf "%-15s" $busyboxOffset)/; \
  0,/@busyboxSize@/s//$(printf "%-13s" "$busyboxSize")/" "$out"/bin/nix-portable.zip

$zip "$out"/bin/nix-portable.zip $bubblewrap/bin/bwrap
$zip "$out"/bin/nix-portable.zip $nix/bin/nix
$zip "$out"/bin/nix-portable.zip $proot/bin/proot
$zip "$out"/bin/nix-portable.zip $zstd/bin/zstd
$zip "$out"/bin/nix-portable.zip $storeTar/tar
$zip "$out"/bin/nix-portable.zip $caBundleZstd

# create fingerprint
fp=$(sha256sum "$out"/bin/nix-portable.zip | head -c64)
sed -i "0,/_FINGERPRINT_PLACEHOLDER_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/s//$fp/" "$out"/bin/nix-portable.zip

if [ "$bundledExe" == "" ]; then
  target="$out/bin/nix-portable"
else
  target="$out/bin/$(basename "$bundledExe")"
fi
mv "$out"/bin/nix-portable.zip "$target"
chmod +x "$target"
