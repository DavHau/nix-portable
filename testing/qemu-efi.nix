# http://snapshots.linaro.org/components/kernel/leg-virt-tianocore-edk2-upstream/4443/QEMU-ARM/RELEASE_GCC5/QEMU_EFI.img.gz

{
  fetchurl,
  gzip,
  runCommand,
}:

let
  qemu-efi-gz = fetchurl {
    url = "http://snapshots.linaro.org/components/kernel/leg-virt-tianocore-edk2-upstream/4443/QEMU-AARCH64/RELEASE_GCC5/QEMU_EFI.img.gz";
    sha256 = "sha256-bOO6bsiwHaf39TWdkxOYWOw9p+/EzCkZLzi5YQPZTLY=";
  };
in

runCommand "QEMU_EFI.img" {} ''
  cp ${qemu-efi-gz} QEMU_EFI.img.gz
  ${gzip}/bin/gunzip QEMU_EFI.img.gz
  mv QEMU_EFI.img $out
''
