{ lib, pkgs, ... }:

let
  exoGpuWiredLimits = pkgs.writeTextFile {
    name = "exo-gpu-wired-limits";
    executable = true;
    destination = "/bin/exo-gpu-wired-limits";
    text = builtins.readFile ./../scripts/exo-gpu-wired-limits.sh;
  };
in
{
  environment.systemPackages = [ exoGpuWiredLimits ];

  launchd.daemons."exo-gpu-wired-limits" = {
    command = "${exoGpuWiredLimits}/bin/exo-gpu-wired-limits";
    serviceConfig = {
      RunAtLoad = true;                         # run at boot / activation
      KeepAlive = false;                        # set to { SuccessfulExit = false; } if you want retries
      # Uncomment to re-apply periodically (e.g., every 30 minutes):
      # StartInterval = 1800;

      StandardOutPath = "/var/log/exo-gpu-wired-limits.log";
      StandardErrorPath = "/var/log/exo-gpu-wired-limits.err";

      # Tune via environment (same names as the script’s vars)
      EnvironmentVariables = {
        PCT_HIGH = "80";
        PCT_LOW  = "70";
        FLOOR_MINUS_MB_HIGH = "5120";
        FLOOR_MINUS_MB_LOW  = "8192";
      };
    };
  };
}
