{
  pkgs,
  lib,
  config,
  ...
}:
let
  cfg = config.services.cirrus-runner;
  constants = import ../constants.nix;

  MOUNTED_CONFIG_FILE_PATH = "/etc/cirrus/worker.yml";
  VM_CONFIG_FILE_PATH = "${constants.CIRRUS_WORKER_WORKDIR}/cirrus/worker.yml";

  CIRRUS_WORKER_USER = "cirrus-worker";
  CIRRUS_WORKER_GROUP = "cirrus-worker";

  DOCKER_SOCKET_FILE = "/run/user/8333/docker.sock";

  # The existance of files is used to indicate the shut down the VM. A delayed
  # shut down after a longer delay. This file is created immediatly after the
  # cirrus-runner exits. This is a safe guard against some other ExecStopPost
  # failing. An instant shutdown file is created after all other ExecStopPost
  # scripts (like e.g. exporting docker images for Ubuntu, centos, ..) are done.
  # While a mallicous job can create these files, the only thing it can do is to
  # shut down the VM and fail/end the task.
  DELAYED_SHUTDOWN_FILE = "${constants.CIRRUS_WORKER_WORKDIR}/delayed-shutdown";
  INSTANT_SHUTDOWN_FILE = "${constants.CIRRUS_WORKER_WORKDIR}/instant-shutdown";

  patched-cirrus-cli = pkgs.cirrus-cli.overrideAttrs (oldAttrs: rec {
    version = "22729156d1e508ec16b1bc98f59d1ffc6249927e";
    src = pkgs.fetchFromGitHub {
      owner = "0xb10c";
      repo = "cirrus-cli";
      rev = version;
      sha256 = "sha256-+BjY0oNkVcwttT8gfXZm0vWLOyGJyEjypIKl144ADUg=";
    };
    vendorHash = "sha256-+OMhaAGA+pmiDUyXDo9UfQ0SFEAN9zuNZjnLkgr7a+0=";
  });

  # Save the docker base images
  save-docker-images-sh = "${pkgs.writeShellScript "save-docker-images.sh" ''
    set -o xtrace
    images=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "ci_")
    for image in $images; do
      creation_date=$(docker images --format '{{.CreatedAt}}' $image | ${pkgs.gawk}/bin/awk -F " " '{print $1}')
      repo_tag_id=$(docker images --format '{{.Repository}}+{{.Tag}}+{{.ID}}' $image | tr '/' '@')
      filename="$creation_date+$repo_tag_id.tar"
      if [ ! -f "/cache/docker/base-imgs/$filename" ]; then
        docker save -o "/cache/docker/base-imgs/$filename" "$image" && echo "Saved $image to $filename.tar" || true
      fi
    done
  ''}";

  wait-for-docker-sh = "${pkgs.writeShellScript "wait-for-docker.sh" ''
    set -o xtrace
    FILE_TO_CHECK="${DOCKER_SOCKET_FILE}"
    # Number of attempts
    MAX_ATTEMPTS=20

    # Counter for attempts
    attempt=0

    while [[ $attempt -lt $MAX_ATTEMPTS ]]
    do
        if [[ -e "$FILE_TO_CHECK" ]]; then
            echo "File exists: $FILE_TO_CHECK"
            exit 0
        else
            echo "Attempt $((attempt + 1)): File does not exist. Retrying in 1 second..."
        fi
        sleep 1
        ((attempt++))
    done
    echo "Docker socket did not exist after $attempt attempts. Shutting the VM down.."
    ${pkgs.coreutils-full}/bin/touch ${DELAYED_SHUTDOWN_FILE}
    exit 1
  ''}";
  load-docker-images-sh = "${pkgs.writeShellScript "load-docker-images.sh" ''
    set -o xtrace
    DIRECTORY="/cache/docker/base-imgs"
    # ensure we sort the base images. They start with the date they were
    # created, which means newer images are tagged later. This sets the
    # tag on the newer image (as the old tag is overwritten by the next
    # `docker tag`)
    export LC_COLLATE=C
    for FILE in $(ls "$DIRECTORY" | sort); do
      if [ -f "$DIRECTORY/$FILE" ]; then
        ${pkgs.docker}/bin/docker load --input $DIRECTORY/$FILE || true
        base=$(basename $FILE)
        id=$(echo $base | sed 's/\.tar//g' | ${pkgs.gawk}/bin/awk -F "+" '{print $4}')
        tag=$(echo $base | ${pkgs.gawk}/bin/awk -F "+" '{print $2 ":" $3}' | tr '@' '/')
        ${pkgs.docker}/bin/docker tag $id $tag || true
      fi
    done
  ''}";
in
{

  options.services.cirrus-runner = {
    enable = lib.mkEnableOption "enable the cirrus runner";

    name = lib.mkOption {
      type = lib.types.str;
      default = null;
      description = "The name of the cirrus worker.";
    };

    size = lib.mkOption {
      type = lib.types.str;
      default = null;
      description = "The size (type) of the cirrus worker. Either small or medium.";
    };

  };

  config = lib.mkIf cfg.enable {

    # The cirrus worker gets its own temporary copy of the configuration file.
    # This file is removed after cirrus-cli has read it to ensure a CI script
    # can't read it, which would expose the runner token allowing to spawn
    # malicious workers.
    systemd.services.setup-cirrus-worker-config = {
      description = "Cirrus CI worker config creation";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "cirrus-worker.service" ];
      script = ''
        cp ${MOUNTED_CONFIG_FILE_PATH} ${VM_CONFIG_FILE_PATH}
        chown ${CIRRUS_WORKER_USER}:${CIRRUS_WORKER_GROUP} ${VM_CONFIG_FILE_PATH}
        chmod 600 ${VM_CONFIG_FILE_PATH}
        echo "Copied cirrus worker config file to ${VM_CONFIG_FILE_PATH} read-writable by ${CIRRUS_WORKER_USER}:${CIRRUS_WORKER_GROUP}"

        stat ${MOUNTED_CONFIG_FILE_PATH}
      '';
      serviceConfig = {
        Type = "oneshot";
        User = "root"; # only root can read the config file
      };
    };

    systemd.services.cirrus-worker = {
      description = "Cirrus CI Worker";
      after = [
        "network-online.target"
        "setup-cirrus-worker-config.service"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = constants.defaultHardening // {
        ExecStartPre = [
          # Wait for the docker.sock to appear, timeout after a while
          wait-for-docker-sh
          # Try to load existing docker base images (Ubuntu, centos, ..)
          load-docker-images-sh
        ];
        ExecStart = "${pkgs.bash}/bin/bash -c '${patched-cirrus-cli}/bin/cirrus worker run --file ${VM_CONFIG_FILE_PATH} --name ${cfg.name} --labels type=${cfg.size} --ephemeral'";
        ExecStartPost = "${pkgs.bash}/bin/bash -c 'sleep 2 && ${pkgs.coreutils}/bin/rm ${VM_CONFIG_FILE_PATH} && echo \"removed cirrus worker config file ${VM_CONFIG_FILE_PATH}\"'";
        ExecStopPost = [
          # Create the DELAYED_SHUTDOWN_FILE. Even if any other ExecStopPost script fails, the vm will shut down eventually.
          "${pkgs.coreutils-full}/bin/touch ${DELAYED_SHUTDOWN_FILE}"

          # save the (Ubuntu, Centos, ..) docker images
          save-docker-images-sh

          # As a last step, create the INSTANT_SHUTDOWN_FILE to shut the VM down.
          "${pkgs.coreutils-full}/bin/touch ${INSTANT_SHUTDOWN_FILE}"
        ];
        User = CIRRUS_WORKER_USER;
        Group = CIRRUS_WORKER_GROUP;
        WorkingDirectory = constants.CIRRUS_WORKER_WORKDIR;
        # Loading the docker images can take a while if all VMs load them at
        # the same time. To avoid the cirrus-worker failing to start, time out
        # only after 300 secs.
        TimeoutStartSec = "300";
        # ProtectHome = true disables access to DOCKER_SOCKET_FILE
        # This overwrites a defaultHardening setting.
        ProtectHome = false;
        ReadWriteDirectories = [
          # Allow the cirrus-worker service to read & write to CIRRUS_WORKER_WORKDIR/cirrus. It
          # will remove the worker.yml config there once it has started up.
          "${constants.CIRRUS_WORKER_WORKDIR}/"
          # Allow the cirrus-worker service to read & write /cache.
          "/cache"
        ];
        # Deny the cirrus worker service to connect to local IP addresses. This
        # overwrites the "any" defaultHardening setting. The service needs to
        # connect to different IP addresses depending on the CI job, we can't
        # limit them here.
        IPAddressDeny = [
          "localhost"
          "link-local"
          "multicast"
        ];
      };
      environment = {
        PATH = lib.mkForce (
          lib.makeBinPath [
            # as mentioned in https://github.com/bitcoin/bitcoin/tree/master/ci#running-a-stage-locally
            pkgs.bash
            pkgs.docker
            pkgs.python3
            # also required
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.git
          ]
        );
        # The cirrus-worker will create $TMPDIR/cirrus-build, which docker will
        # bind mount (during `docker run` in ci/test/02_run_container.sh). If
        # this would be under /tmp/, with systemd's PrivateTmp = true, docker
        # would not be able to see the directory.
        TMPDIR = "${constants.CIRRUS_WORKER_WORKDIR}/tmp";
        XDG_CACHE_HOME = "${constants.CIRRUS_WORKER_WORKDIR}/.cache";
        DOCKER_HOST = "unix://${DOCKER_SOCKET_FILE}";
        # The host has a big ccache. Use it in during the build.
        # This is a Bitcoin Core CI configuration option.
        CCACHE_DIR = "/ci_container_base/ccache";
        # The host is managing the ccache size and trimming. Don't
        # try to do it in the VM (0 sets no-limit).
        # This is a Bitcoin Core CI configuration option.
        CCACHE_MAXSIZE = "0";
        # By default, the CI will cache depends (sources & built) and
        # prev_releases in docker volumes. However, the VMs are ephemeral
        # and we don't keep the docker volumes. Rather, use 'bind' mounts
        # to folders on the "disk". These folders are mounted on /cache
        # and are symlinked to the expected locations below.
        # This is a Bitcoin Core CI configuration option.
        DANGER_CI_ON_HOST_CACHE_FOLDERS = "true";
        # Set the extra docker build arguments to cache the build steps.
        # This is a Bitcoin Core CI configuration option.
        # See https://github.com/bitcoin/bitcoin/pull/31545
        DANGER_DOCKER_BUILD_CACHE_HOST_DIR = "/cache/docker/ci-imgs";
      };
    };

    systemd.services = {
      delayed-shutdown-on-file = {
        description = "Schedule a shutdown the system when ${DELAYED_SHUTDOWN_FILE} exists";
        serviceConfig = constants.defaultHardening // {
          User = CIRRUS_WORKER_USER;
          Group = CIRRUS_WORKER_GROUP;
          # NoNewPrivileges=false is needed to shut down the VM via the setuid
          # /run/wrappers/bin/vm-shutdown binary. However, we don't want to set
          # NoNewPrivileges=false on the cirrus-worker service. Do in this task
          # with a much more limited scope than the cirrus-worker service which
          # litterally executes remote code supplied by users.
          # This overwrites a defaultHardening setting.
          NoNewPrivileges = false;
          Type = "oneshot";
          ExecStart = "/run/wrappers/bin/vm-shutdown --poweroff +5 'Cirrus job done - delayed-shutdown'";
          RestartSec = 60;
          Restart = "on-failure";
        };
        unitConfig = {
          ConditionPathExists = DELAYED_SHUTDOWN_FILE;
        };
      };
      instant-shutdown-on-file = {
        description = "Shutdown the system when ${INSTANT_SHUTDOWN_FILE} exists";
        serviceConfig = constants.defaultHardening // {
          User = CIRRUS_WORKER_USER;
          Group = CIRRUS_WORKER_GROUP;
          # NoNewPrivileges=false is needed to shut down the VM via the setuid
          # /run/wrappers/bin/vm-shutdown binary. However, we don't want to set
          # NoNewPrivileges=false on the cirrus-worker service. Do in this task
          # with a much more limited scope than the cirrus-worker service which
          # litterally executes remote code supplied by users.
          # This overwrites a defaultHardening setting.
          NoNewPrivileges = false;
          Type = "oneshot";
          ExecStart = "/run/wrappers/bin/vm-shutdown --poweroff now 'VM done - instant-shutdown'";
          RestartSec = 60;
          Restart = "on-failure";
        };
        unitConfig = {
          ConditionPathExists = INSTANT_SHUTDOWN_FILE;
        };
      };
    };

    systemd.paths = {
      instant-shutdown-on-file = {
        description = "Watch for ${INSTANT_SHUTDOWN_FILE} and trigger the instant shutdown service";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathExists = INSTANT_SHUTDOWN_FILE;
        };
      };
      delayed-shutdown-on-file = {
        description = "Watch for ${DELAYED_SHUTDOWN_FILE} and trigger the delayed shutdown service";
        wantedBy = [ "multi-user.target" ];
        pathConfig = {
          PathExists = DELAYED_SHUTDOWN_FILE;
        };
      };
    };

    # create a setuid wrapper for systemd-shutdown. This allows the
    # unprivileged cirrus-worker user to shutdown the VM after the
    # job finishes.
    security.wrappers = {
      vm-shutdown = {
        setuid = true;
        owner = "root";
        group = "root";
        source = "${pkgs.systemd}/bin/shutdown";
      };
    };

    users.users."${CIRRUS_WORKER_USER}" = {
      isSystemUser = true;
      group = CIRRUS_WORKER_GROUP;
      description = "Cirrus CI worker user";
      home = constants.CIRRUS_WORKER_WORKDIR;
      createHome = true;
      uid = 8333;
      shell = pkgs.bash;
      # linger is needed for rootless docker
      linger = true;
      # subUidRanges and subGidRanges are needed for rootless docker
      subUidRanges = [
        {
          startUid = 100000;
          count = 65536;
        }
      ];
      subGidRanges = [
        {
          startGid = 100000;
          count = 65536;
        }
      ];
    };
    users.groups."${CIRRUS_WORKER_GROUP}" = {
      gid = 8333;
    };

    systemd.tmpfiles.rules = [
      # Create the working directory of the cirrus-worker.
      "d '${constants.CIRRUS_WORKER_WORKDIR}'                0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      "d '${constants.CIRRUS_WORKER_WORKDIR}/cirrus'         0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      "d '${constants.CIRRUS_WORKER_WORKDIR}/docker'         0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      "d '${constants.CIRRUS_WORKER_WORKDIR}/tmp'            0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      # Create the working directory of the CI.
      "d '/ci_container_base'                   0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      "d '/cache'                               0700 ${CIRRUS_WORKER_USER} ${CIRRUS_WORKER_GROUP} -"
      # Symlink the working directories to the persistent counterparts.
      "L '/ci_container_base/depends'           -    -           -            -  /cache/depends/"
      "L '/ci_container_base/prev_releases'     -    -           -            -  /cache/prev_releases"
      "L '/ci_container_base/ccache'            -    -           -            -  /cache/ccache"
    ];
  };
}
