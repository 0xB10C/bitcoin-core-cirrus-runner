# based on
# https://git.scottworley.com/nixos-qemu-vm-isolation/blob/1c40de51f4927c338c3eb981d4aaeafdd6919cac:/modules/qemu-vm-isolation.nix
{
  config,
  lib,
  modulesPath,
  pkgs,
  ...
}:
let
  inherit (lib)
    escapeShellArg
    mkForce
    mkIf
    mkMerge
    mkOption
    mkVMOverride
    optional
    ;

  cfg = config.virtualisation.qemu.isolation;

  storeMountPath = if config.virtualisation.writableStore then "/nix/.ro-store" else "/nix/store";

  hostPkgs = config.virtualisation.host.pkgs;

  storeContents = hostPkgs.closureInfo { rootPaths = config.virtualisation.additionalPaths; };

  nixStoreImages = {
    ext4 = "${
      import (modulesPath + "/../lib/make-disk-image.nix") {
        inherit pkgs config lib;
        additionalPaths = [ storeContents ];
        onlyNixStore = true;
        label = "nix-store";
        partitionTableType = "none";
        installBootLoader = false;
        diskSize = "auto";
        additionalSpace = "0M";
        copyChannel = false;
      }
    }/nixos.img";
    erofs = "${
      hostPkgs.runCommand "nix-store-image" { } ''
        mkdir $out
        ${hostPkgs.gnutar}/bin/tar --create \
          --absolute-names \
          --verbatim-files-from \
          --transform 'flags=rSh;s|/nix/store/||' \
          --files-from ${storeContents}/store-paths \
          | ${hostPkgs.erofs-utils}/bin/mkfs.erofs \
            --force-uid=0 \
            --force-gid=0 \
            -L nix-store \
            -U eb176051-bd15-49b7-9e6b-462e0b467019 \
            -T 0 \
            --tar=f \
            $out/nix-store.img
      ''
    }/nix-store.img";
    squashfs = "${hostPkgs.callPackage (modulesPath + "/../lib/make-squashfs.nix") {
      storeContents = config.virtualisation.additionalPaths;
    }}";
  };

in
{
  options = {
    virtualisation.qemu.isolation.nixStoreFilesystemType = mkOption {
      description = ''
        What filesystem to use for the guest's Nix store.

        erofs is more compact than ext4, but less mature.

        squashfs support currently requires a dubious kludge that results in these
        VMs not being able to mount any other squashfs volumes besides the nix store.
      '';
      type = lib.types.enum [
        "ext4"
        "erofs"
        "squashfs"
      ];
      default = "ext4";
    };
  };
  config = mkMerge [
    {
      boot.initrd.kernelModules = optional (cfg.nixStoreFilesystemType == "erofs") "erofs";

      nixpkgs.overlays = optional (cfg.nixStoreFilesystemType == "squashfs") (
        final: prev: {
          util-linux = prev.util-linux.overrideAttrs (old: {
            patches = (old.patches or [ ]) ++ [ ./libblkid-squashfs-nix-store-kludge.patch ];
          });
        }
      );

      fileSystems = mkVMOverride {
        "${storeMountPath}" = {
          fsType = cfg.nixStoreFilesystemType;
          options = [ "ro" ];
          neededForBoot = true;
          label = "nix-store";
        };
      };

      system.build.nixStoreImage = nixStoreImages."${cfg.nixStoreFilesystemType}";

      virtualisation = {

        sharedDirectories = mkForce { };

        qemu.drives = [
          {
            file = config.system.build.nixStoreImage;
            driveExtraOpts = {
              format = "raw";
              read-only = "on";
              werror = "report";
            };
          }
        ];

      };
    }
    (mkIf (cfg.nixStoreFilesystemType == "ext4") {
      # We use this to disable fsck runs on the ext4 nix store image because stage-1
      # fsck crashes (maybe because the device is read-only?), halting boot.
      boot.initrd.checkJournalingFS = false;
    })
  ];
}
