{
  config,
  pkgs,
  lib,
  ...
}: let
  inherit (lib) mkOption;
  inherit (lib) types;
in {
  options = {
    system = {
      systemBuilderCommands = mkOption {
        type = types.lines;
        internal = true;
        default = "";
        description = ''
          This code will be added to the builder creating the system store path.
        '';
      };

      systemBuilderArgs = mkOption {
        type = types.attrsOf types.unspecified;
        internal = true;
        default = {};
        description = ''
          `lib.mkDerivation` attributes that will be passed to the top level system builder.
        '';
      };
    };
  };

  config = {
    boot.kernelParams = ["init=${config.system.build.initialRamdisk}/initrd"];
    system.build = {
      # TODO: this makes it so that the build closure depends on qemu no matter what.
      # We should make this optional, or even better, an imported profile.
      runvm = pkgs.writeShellScriptBin "micros-vm-runner" ''
        exec ${pkgs.qemu_kvm}/bin/qemu-kvm -name micros -m 512 \
          -drive index=0,id=drive1,file=${config.system.build.squashfs},readonly,media=cdrom,format=raw,if=virtio \
          -kernel ${config.system.build.kernel}/bzImage \
          -initrd ${config.system.build.initialRamdisk}/initrd -nographic \
          -append "console=ttyS0 ${toString config.boot.kernelParams} quiet panic=-1" -no-reboot \
          -net nic,model=virtio \
          -net user,net=10.0.2.0/24,host=10.0.2.2,dns=10.0.2.3,hostfwd=tcp::2222-:22 \
          -device virtio-rng-pci
      '';

      image = pkgs.callPackage (pkgs.path + "/nixos/lib/make-iso9660-image.nix") {
        contents = [
          {
            source = config.system.build.kernel + "/bzImage";
            target = "/boot/bzImage";
          }
          {
            source = config.system.build.initialRamdisk + "/initrd";
            target = "/boot/initrd";
          }
          {
            source = config.system.build.squashfs;
            target = "/root.squashfs";
          }
          {
            source = "${pkgs.syslinux}/share/syslinux";
            target = "/isolinux";
          }
          {
            source = pkgs.writeText "isolinux.cfg" ''
              SERIAL 0 115200
              TIMEOUT 35996

              DEFAULT boot

              LABEL boot
              MENU LABEL Boot Micros
              LINUX /boot/bzImage
              APPEND console=ttyS0 root=LABEL=micros init=${config.system.build.initialRamdisk}/initrd ${toString config.boot.kernelParams}
              INITRD /boot/initrd
            '';
            target = "/isolinux/isolinux.cfg";
          }
        ];
        isoName = "micros-image.iso";
        volumeID = "micros";
        bootable = true;
        bootImage = "/isolinux/isolinux.bin";
        usbBootable = true;
        isohybridMbrImage = "${pkgs.syslinux}/share/syslinux/isohdpfx.bin";
        syslinux = pkgs.syslinux;
      };
      # nix-build -A system.build.toplevel && du -h $(nix-store -qR result) --max=0 -BM|sort -n
      toplevel =
        pkgs.runCommand "micros-toplevel" {
          activationScript = config.system.activationScripts.script;
        } ''
          mkdir $out

          cp ${config.system.build.bootStage2} $out/init
          substituteInPlace $out/init --subst-var-by systemConfig $out
          ln -s ${config.system.path} $out/sw
          echo "$activationScript" > $out/activate
          substituteInPlace $out/activate --subst-var out
          chmod u+x $out/activate

          unset activationScript
        '';

      squashfs = pkgs.callPackage (pkgs.path + "/nixos/lib/make-squashfs.nix") {
        storeContents = [config.system.build.toplevel];
      };
    };
  };
}
