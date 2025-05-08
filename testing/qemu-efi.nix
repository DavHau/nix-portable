# http://snapshots.linaro.org/components/kernel/leg-virt-tianocore-edk2-upstream/4443/QEMU-ARM/RELEASE_GCC5/QEMU_EFI.img.gz

{
  fetchurl,
  runCommand,
  buildPackages,
}:

let
  qemu-efi-gz = fetchurl {
    url = "http://snapshots.linaro.org/components/kernel/leg-virt-tianocore-edk2-upstream/4801/QEMU-AARCH64/RELEASE_GCC5/QEMU_EFI.img.gz";
    sha256 = "sha256-Rfio8FtcXrVslz+W6BsSV0xHvxwHLfqGhJMs2Kc3B30=";
  };
in

runCommand "QEMU_EFI.img" {} ''
  cp ${qemu-efi-gz} QEMU_EFI.img.gz
  ${buildPackages.gzip}/bin/gunzip QEMU_EFI.img.gz
  mv QEMU_EFI.img $out
''
