{ pkgs, lib, ... }:

let

  PROMETHEUS_EXPORTER_PORT_SMALL = 9500;
  PROMETHEUS_EXPORTER_PORT_MEDIUM = 9501;
  
in
{
  name = "basic";

  nodes.machine =
    { config, lib, ... }:
    {
      imports = [ ../module.nix ];
      virtualisation.cores = 2;
      virtualisation.memorySize = 3 * 1024;

      # DANGER: in a production setup, this should be a secret and not hardcoded
      # in a world (and VM!) readable nix store
      environment.etc."cirrus/worker.yml" = {
        text = "token: abc";
      };

      services.cirrus-ephemeral-vm-runner = {
        enable = true;
        name = "basic-test";
        vms = {
          small = {
            count = 1;
            cpu = 1;
            memory = 1;
          };
          medium = {
            count = 1;
            cpu = 1;
            memory = 1;
          };
        };
      };
    };

  # tests that the configuration evaluates, the VMs start and are reachable.
  # Does not test that the VMs remain online or do something.
  testScript = ''
    # Don't start grafana at the beginning.
    machine.succeed("systemctl stop grafana.service")

    machine.wait_for_unit("cirrus-vm0small.service", timeout=20)
    machine.wait_for_unit("cirrus-vm1medium.service", timeout=20)

    # ssh port of cirrus-vm0small
    machine.wait_for_open_port(2000, timeout=60)
    machine.wait_for_open_port(${toString PROMETHEUS_EXPORTER_PORT_SMALL}, timeout=60)

    # ssh port of cirrus-vm1medium
    machine.wait_for_open_port(2001, timeout=60)
    machine.wait_for_open_port(${toString PROMETHEUS_EXPORTER_PORT_MEDIUM}, timeout=60)

    machine.succeed("systemctl start grafana.service")
    # TOOD: don't hardcode grafana port
    # machine.wait_for_open_port(1234, timeout=15)

    # wait until the node exporter on the VMs is online
    machine.wait_until_succeeds("${pkgs.curl}/bin/curl http://127.0.0.1:${toString PROMETHEUS_EXPORTER_PORT_SMALL}", timeout=60)
    machine.wait_until_succeeds("${pkgs.curl}/bin/curl http://127.0.0.1:${toString PROMETHEUS_EXPORTER_PORT_MEDIUM}", timeout=60)

  '';
}
