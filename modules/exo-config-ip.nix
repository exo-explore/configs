{ lib, pkgs, ... }:

let
  # Build the script into the Nix store without any interpolation issues
  exoConfigIp = pkgs.writeTextFile {
    name = "exo-config-ip";
    executable = true;
    destination = "/bin/exo-config-ip";
    text = builtins.readFile ./../scripts/exo-config-ip.sh;
  };
in
{
  environment.systemPackages = [ exoConfigIp ];

  launchd.daemons."exo-config-ip" = {
    command = "${exoConfigIp}/bin/exo-config-ip";
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = { NetworkState = true; };  # rerun when interfaces change
      StandardOutPath = "/var/log/exo-config-ip.log";
      StandardErrorPath = "/var/log/exo-config-ip.err";

      # Defaults; override per host in your flake if needed
      EnvironmentVariables = {
        WIFI_SERVICE = "Wi-Fi";
        LAN_PREFIX   = "192.168.1";
        NETMASK      = "255.255.255.0";
        # WIRED_SERVICE = "Thunderbolt Ethernet"; # uncomment to pin a device name
      };
    };
  };
}
