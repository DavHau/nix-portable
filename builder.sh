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
patchelf=@patchelf@

set -x

# https://github.com/NixOS/nixpkgs/blob/e101e9465d47dd7a7eb95b0477ae67091c02773c/lib/strings.nix#L1716
function removePrefix() {
  local prefix="$1"
  local str="$2"
  local preLen=${#prefix}
  if [[ "${str:0:$preLen}" == "$prefix" ]]; then
    echo "${str:$preLen}"
  else
    echo "$str"
  fi
}

add_file_list=()

# in stage1, we only have bash and coreutils
# so we cannot unzip busybox, so we get the file offsets
# se we can unpack files with "tail" and "head" commands
# tail -c+$((offset + 1)) $zip | head -c$size

stage1_file_path_list=()
stage1_file_offset_list=()
stage1_file_size_list=()

# add a stage1 executable file and its dependencies (libraries)
function add_stage1_bin() {
  local bin="$1"
  if add_file -1 "$bin"; then
    echo
    echo "adding binary: $bin"
    add_stage1_libs "$bin"
    echo
    # exit 1 # debug
  fi
}

# add stage1 library files
function add_stage1_libs() {
  local bin="$1"
  # ldd "$bin" # debug
  for lib in $(ldd "$bin" 2>/dev/null | grep -oE '/nix/store/[^ ]+'); do
    # echo "  adding library: $lib"
    if add_file -1 "$lib"; then
      # recurse: add dependencies of lib
      add_stage1_libs "$lib"
    fi
  done
}

function add_stage1_file_offset_size() {
  local file="$1"
  #local size=$(stat -c %s "$file")
  local size=$(stat -c %s -L "$file") # dereference symlinks
  local hash=$(sha1sum "$file" | head -c40)
  # locate the first 1000 bytes of file in the zip archive
  local grep_size=1000
  if ((grep_size > size)); then grep_size=$size; fi
  local skip=0
  if [ ${#stage1_file_offset_list[@]} != 0 ]; then
    # start search from previous file
    # skip bytes until previous offset + size
    skip=$((${stage1_file_offset_list[-1]} + ${stage1_file_size_list[-1]}))
  fi
  # exploit that files are appended
  while read offset; do
    offset=$((offset / 2)) # hex to bin
    offset=$((skip + offset))
    # debug
    # echo "zipped file header:"
    # tail -c+$((offset + 1)) "$out"/bin/nix-portable.zip | head -c1000 | basenc --base16 -w0 || true
    # verify offset
    # FIXME tail: error writing 'standard output': Broken pipe
    set +o pipefail
    hash2=$(tail -c+$((offset + 1)) "$out"/bin/nix-portable.zip | head -c"$size" |
      sha1sum - | head -c40 || true)
    set -o pipefail
    if [ "$hash" = "$hash2" ]; then
      stage1_file_offset_list+=("$offset")
      stage1_file_size_list+=("$size")
      return
    fi
  done < <(
    # bin to hex
    # rg is 25x faster than grep
    # basenc is 10x faster than xxd
    tail -c+$((skip + 1)) "$out"/bin/nix-portable.zip | basenc --base16 -w0 |
    rg -boF $(head -c"$grep_size" "$file" | basenc --base16 -w0) |
    cut -d: -f1
  )
  echo "error: file was not found in zip archive: $file"
  exit 1
}

defer_zip=false # dt: 10.5362 # TODO remove
defer_zip=true # dt: 3.20238

function add_file() {
  local is_stage1=false
  if [ "$1" = "-1" ]; then is_stage1=true; shift; fi
  local file="$1"
  if $is_stage1; then
    # change file path to build a FHS filesystem layout for stage1
    local file2="stage1/${file#/*/*/*/*}"
    if ! [ -e "$file2" ]; then
      mkdir -p "${file2%/*}"
      cp -Lp "$file" "$file2"
      chmod +w "$file2"
    fi
    file="$file2"
    # set relative rpath to create relocatable bins and libs
    $patchelf/bin/patchelf --set-rpath '$ORIGIN/../lib' "$file"
    # FIXME patch interpreter paths like /nix/store/rmy663w9p7xb202rcln4jjzmvivznmz8-glibc-2.40-66/lib/ld-linux-x86-64.so.2
    # no. this is not working
    # https://stackoverflow.com/questions/48452793/using-origin-to-specify-the-interpreter-in-elf-binaries-isnt-working
    #$patchelf/bin/patchelf --set-interpreter '$ORIGIN/../lib' "$file"
  fi
  if ! $defer_zip; then
  # dont defer the zip command = add one file now
  # check if file exists in zip archive
  if unzip -p "$out"/bin/nix-portable.zip "$(removePrefix "/" "$file")" 2>/dev/null | head -c0; then
    return 1
  fi
  $zip "$out"/bin/nix-portable.zip "$file"
  if $is_stage1; then
    stage1_file_path_list+=("$file")
    add_stage1_file_offset_size "$file"
  fi
  else
  # defer the zip command = add all files later
  # check if file exists in zip archive
  local f
  for f in "${add_file_list[@]}"; do
    if [ "$f" = "$file" ]; then
      return 1
    fi
  done
  echo "  adding file: $file"
  add_file_list+=("$file")
  if $is_stage1; then stage1_file_path_list+=("$file"); fi
  fi
}

function dump_array() {
  local name=$1
  local -n arr=$1
  echo "$name=("
  local val
  for val in "${arr[@]}"; do
    printf "%q\n" "$val"
  done
  echo ")"
}

function assert_equal_array_size() {
  local -n name1=$1
  local -n arr1=$1
  shift
  local size1=${#arr1[@]}
  while (($# > 0)); do
    local -n name2=$1
    local -n arr2=$1
    shift
    local size2=${#arr2[@]}
    if [ "$size1" != "$size2" ]; then
      echo "error: $name2 should have $size1 values, has $size2"
      return 1
    fi
  done
}

function add_file_done() {
  if $defer_zip; then
    $zip "$out"/bin/nix-portable.zip "${add_file_list[@]}"
    add_file_list=()
    local file
    for file in "${stage1_file_path_list[@]}"; do
      add_stage1_file_offset_size "$file"
    done
  fi
  rm -rf stage1
  # check internal consistency
  assert_equal_array_size \
    stage1_file_path_list \
    stage1_file_offset_list \
    stage1_file_size_list
  # store file offsets in the zip archive
  {
    dump_array stage1_file_path_list
    dump_array stage1_file_offset_list
    dump_array stage1_file_size_list
  } >stage1_files.sh
  touch -d1970-01-01 stage1_files.sh
  stage1_file_path_list=()
  stage1_file_offset_list=()
  stage1_file_size_list=()
  # add_file -1 stage1_files.sh
  $zip "$out"/bin/nix-portable.zip stage1_files.sh
  add_stage1_file_offset_size stage1_files.sh
  rm stage1_files.sh
  stage1_files_sh_offset=${stage1_file_offset_list[0]}
  stage1_files_sh_size=${stage1_file_size_list[0]}
  stage1_file_path_list=()
  stage1_file_offset_list=()
  stage1_file_size_list=()
  sed -i "0,/@stage1_files_sh_offset@/s//$(printf "%-24s" "$stage1_files_sh_offset")/; \
    0,/@stage1_files_sh_size@/s//$(printf "%-22s" "$stage1_files_sh_size")/" "$out"/bin/nix-portable.zip
}

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

# we cannot unzip busybox, so we need offset and size of all needed files (bins and libs)
# add_file does not work here
#$zip $out/bin/nix-portable.zip $busybox/bin/busybox
add_stage1_bin $busybox/bin/busybox

t1=$(date +%s.%N)

#add_stage1_bin $bubblewrap/bin/bwrap
#add_stage1_bin $proot/bin/proot
add_stage1_bin $zstd/bin/zstd
#add_stage1_bin $nix/bin/nix # 150M result/bin/nix-portable
# # nix needs too many libs, so we dont use add_stage1_bin
# add_file $nix/bin/nix # 99M result/bin/nix-portable

# TODO move stage1_files.sh up in the zip archive for faster access
#stage1_file_done

add_file $storeTar/closureInfo/store-paths
add_file $storeTar/tar
add_file $caBundleZstd

add_file_done

t2=$(date +%s.%N)
dt=$(echo "$t1" "$t2" | awk '{ print ($2 - $1) }')
echo "dt: $dt"
# exit 1

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
