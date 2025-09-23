{ lib, pkgs, ... }:

let
  # Package the shell script verbatim from ../scripts
  exoRepoSync = pkgs.writeTextFile {
    name = "exo-repo-sync";
    executable = true;
    destination = "/bin/exo-repo-sync";
    text = builtins.readFile ./../scripts/exo-repo-sync.sh;
  };
in
{
  environment.systemPackages = [ exoRepoSync ];

  launchd.daemons."exo-repo-sync" = {
    command = "${exoRepoSync}/bin/exo-repo-sync";
    serviceConfig = {
      # Defaults you can override per-host in flake.nix
      RunAtLoad     = lib.mkDefault true;
      KeepAlive     = lib.mkDefault false;
      StartInterval = lib.mkDefault 900;  # every 15 minutes

      # Log defaults (host override can point to ~/Library/Logs)
      StandardOutPath  = lib.mkDefault "/var/log/exo-repo-sync.log";
      StandardErrorPath = lib.mkDefault "/var/log/exo-repo-sync.err";

      # Don’t set UserName here; set it per-host so it runs as that user.
      EnvironmentVariables = {
        EXO_REPO_URL_SSH   = lib.mkDefault "git@github.com:exo-explore/exo-v2.git";
        EXO_REPO_URL_HTTPS = lib.mkDefault "https://github.com/exo-explore/exo-v2.git";
        EXO_REPO_BRANCH    = lib.mkDefault "big-refactor";
        EXO_REPO_DEST      = lib.mkDefault "/opt/exo";
        EXO_REPO_OWNER     = lib.mkDefault "root";   # override with the login user
        EXO_DEPLOY_KEY     = lib.mkDefault "";       # empty -> PAT/HTTPS path in script
      };
    };
  };
}

