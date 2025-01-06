{
  pkgs,
  config,
  modulesPath,
  ...
}:

let
  constants = import ../constants.nix;
in
{
  id,
  name,
  size,
  runner_name,
  memory,
  cpu,
}:
{
  imports = [
    (modulesPath + "/virtualisation/qemu-vm.nix")
    # to further trim down on size of the VM:
    (modulesPath + "/profiles/minimal.nix")
    (modulesPath + "/profiles/headless.nix")
    (modulesPath + "/profiles/qemu-guest.nix")
    ./cirrus-runner.nix
    ./nix-store-isolation.nix
  ];

  virtualisation = {
    cores = cpu;
    graphics = false;
    # increased for more p9 file system performance
    msize = (512 * 1024);
    memorySize = (memory * 1024);
    # the nix store in the VM should not be writable
    writableStore = false;
    qemu.virtioKeyboard = false;

    # we overwrite with mkForce here to make sure no other directores are shared
    # By default, NixOS includes the shared and xchg directories.
    sharedDirectories = pkgs.lib.mkForce {
      # A share for the cirrus worker config
      "etc-cirrus" = {
        source = "/var/lib/cirrusvm/${name}/config";
        target = "/etc/cirrus";
        securityModel = "mapped-xattr";
      };
      # A share to an overlayfs of the cache
      "cache" = {
        source = "/var/lib/cirrusvm/${name}/overlay/merged";
        target = "/cache";
        securityModel = "mapped-xattr";
      };
    };

    # use tmpfs for /
    diskImage = null;

    # Don't mount the host's nix-store as it might have tools that make it easier
    # to escape the VM and other more "private" information that might better be
    # isolated from the VMs. The VMs don't need it, so no point in giving them
    # access to it.
    mountHostNixStore = false;
    qemu = {
      drives = [
        {
          name = "docker";
          file = constants.DOCKER_RAW_DISK_LOCATION name;
          driveExtraOpts = {
            format = "raw";
            aio = "io_uring";
            werror = "report";
            # id, if, index are set by NixOS: https://github.com/NixOS/nixpkgs/blob/394571358ce82dff7411395829aa6a3aad45b907/nixos/modules/virtualisation/qemu-vm.nix#L82-L87
          };
        }
      ];
      # build a nix-store erofs image for each VM and mount it. This is using
      # the nix-store-isolation.nix helper.
      isolation.nixStoreFilesystemType = "erofs";
    };

    # A raw disk is used for CIRRUS_WORKER_WORKDIR/docker which is a file on a
    # tmpfs. This is a workaround to docker not working directly on a tmpfs.
    fileSystems."${constants.CIRRUS_WORKER_WORKDIR}/docker" = {
      autoFormat = true;
      # This name was retrieved from the VM via `lsblk`. It might change when
      # adding more disks. Generally, the first disk is vda, the second vdb, ..
      device = "/dev/vdb";
      fsType = "ext4";
      noCheck = true;
    };

    forwardPorts = [
      # forward host port 2000, 2001, .. -> 22, to ssh into the VM
      {
        from = "host";
        host.port = (2000 + id);
        guest.port = 22;
      }
      # forward host port 9501, 9502, .. -> 9200, to scrape prometheus node metrics from the VM
      {
        from = "host";
        host.port = (9500 + id);
        guest.port = 9002;
      }
    ];
  };

  # optimizations from https://github.com/astro/microvm.nix/blob/main/nixos-modules/microvm/optimization.nix

  # Use systemd initrd for startup speed.
  boot.initrd.systemd.enable = true;
  # Exclude switch-to-configuration.pl from toplevel.
  system.switch.enable = false;
  # Also disable other tools that aren't needed:
  system.tools.nixos-build-vms.enable = false;
  system.tools.nixos-enter.enable = false;
  system.tools.nixos-generate-config.enable = false;
  system.tools.nixos-install.enable = false;
  system.tools.nixos-option.enable = false;
  system.tools.nixos-rebuild.enable = false;
  system.tools.nixos-version.enable = false;
  # The docs are pretty chonky
  documentation.enable = false;
  documentation.man.enable = false;
  documentation.doc.enable = false;
  documentation.nixos.enable = false;
  documentation.info.enable = false;
  nix.enable = false;

  services.lvm.enable = false;
  security.sudo.enable = false;
  # hand picked from "/profiles/perlless.nix"
  system.etc.overlay.enable = true;
  system.disableInstallerTools = true;
  programs.less.lessopen = null;
  programs.command-not-found.enable = false;
  boot.enableContainers = false;
  boot.loader.grub.enable = false;

  networking.hostName = name;
  services.sshd.enable = true;

  # Automatically start into journalctl on tty after the machine
  # booted. This allows us to see the VMs log on the host in systemd.
  services.getty = {
    loginProgram = "${pkgs.systemd}/bin/journalctl";
    loginOptions = "--follow --lines 100";
    autologinUser = "journal-reader";
  };
  users.groups.journal-reader = { };
  users.users.journal-reader = {
    isSystemUser = true;
    group = "journal-reader";
  };
  # with profiles/headless.nix, we still want to have ttyS0
  systemd.services."serial-getty@ttyS0".enable = true;

  services.cirrus-runner = {
    enable = true;
    name = "${runner_name}-${name}";
    size = size;
  };

  virtualisation.docker = {
    rootless = {
      enable = true;
      setSocketVariable = true;
      daemon.settings = {
        dns = [
          "8.8.8.8"
          "1.1.1.1"
        ];
        # Have docker store everything on /dev/vdb, which is backed by a raw
        # disk file on a tmpfs on the host.
        data-root = "${constants.CIRRUS_WORKER_WORKDIR}/docker/";
        features = {
          # containered image store is needed to use https://docs.docker.com/build/cache/backends/
          containerd-snapshotter = true;
        };
      };
    };
  };
  # incase the CI docker containers would need to talk to services on the VM, this
  # would need to be enabled. This is kept as dead comment in case it becomes relevant
  # again, but can be removed at some point.
  # systemd.user.services.docker.environment.DOCKERD_ROOTLESS_ROOTLESSKIT_DISABLE_HOST_LOOPBACK = "false";

  services.prometheus = {
    exporters = {
      node = {
        enable = true;
        enabledCollectors = [ "systemd" ];
        port = 9002;
      };
    };
  };
  networking.firewall.allowedTCPPorts = [ config.services.prometheus.exporters.node.port ];

  system.stateVersion = "24.11";
}
