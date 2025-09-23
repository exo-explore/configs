{
  description = "EXO macOS fleet via nix-darwin (+ home-manager) with IP + repo sync daemons";

  inputs = {
    nixpkgs.url       = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darwin.url        = "github:LnL7/nix-darwin";
    home-manager.url  = "github:nix-community/home-manager";
  };

  outputs = { self, nixpkgs, darwin, home-manager, ... }:
  let
    mkHost = {
      hostName,
      userName,
      userEmail ? "eng@exolabs.net",
      system   ? "aarch64-darwin" # "x86_64-darwin" for Intel
    }:
      darwin.lib.darwinSystem {
        inherit system;
        modules = [
          # Home Manager integration
          home-manager.darwinModules.home-manager

          # -------- Host config --------
          ({ pkgs, lib, ... }: {
            # Required by nix-darwin; don't bump casually
            system.stateVersion = 5;

            # User-scoped defaults apply to this user
            system.primaryUser = userName;

            # Share nixpkgs between HM and system
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;

            networking.hostName = hostName;

            # Nix daemon settings
            nix = {
              package = pkgs.nix;
              settings = {
                experimental-features = [ "nix-command" "flakes" ];
                trusted-users = [ "root" userName ];
              };
              gc = {
                automatic = true;
                options = "--delete-older-than 7d";
              };
            };

            # System zsh; user customizations in HM
            programs.zsh.enable = true;

            environment.systemPackages = with pkgs; [
              git uv direnv nix-direnv coreutils jq tmux htop
            ];

            # Ensure the local macOS user exists with this short name
            users.users.${userName} = {
              home = "/Users/${userName}";
              isHidden = false;
              shell = pkgs.zsh;
            };

            # SSH server (password auth disabled; use keys/Tailscale SSH)
            services.openssh = {
              enable = true;
              extraConfig = ''
                PermitRootLogin no
                PasswordAuthentication no
                KbdInteractiveAuthentication no
                ChallengeResponseAuthentication no
                UsePAM yes
              '';
            };

            # Passwordless sudo for admin group (nice for remote ops)
            environment.etc."sudoers.d/10-admin-nopasswd".text = ''
              %admin ALL=(ALL) NOPASSWD: ALL
            '';

            # Avoid nix-darwin PAM symlink in /etc/pam.d
            environment.etc."pam.d/sudo_local".enable = lib.mkForce false;
            # If you want Touch ID later, write a plain file via activation.

            # Tailscale (basic; add extraUpFlags if you want auto-auth)
            services.tailscale.enable = true;

            # Stay awake (no sleep / display sleep)
            system.activationScripts.power.text = ''
              /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1 || true
            '';

            # Best-effort sysctl (many keys are read-only on macOS)
            launchd.daemons."sysctl-tunables" = {
              command = ''${pkgs.bash}/bin/bash -lc '/usr/sbin/sysctl -w net.inet.tcp.msl=1000 || true' '';
              serviceConfig = { RunAtLoad = true; };
            };

            # EXO service: ensure dirs/logs exist; run `uv run exo`
            system.activationScripts.exoDirs.text = ''
              mkdir -p /opt/exo
              chown -R ${userName}:staff /opt/exo || true
              mkdir -p /Users/${userName}/Library/Logs
              chown ${userName}:staff /Users/${userName}/Library/Logs || true
              touch /var/log/exo.log /var/log/exo.err
              chown ${userName}:staff /var/log/exo.log /var/log/exo.err || true
            '';
            launchd.daemons."org.nixos.exo-service" = {
              command = "${pkgs.uv}/bin/uv run exo";
              serviceConfig = {
                RunAtLoad = true;
                KeepAlive = true;
                WorkingDirectory = "/opt/exo";
                StandardOutPath = "/var/log/exo.log";
                StandardErrorPath = "/var/log/exo.err";
                ProcessType = "Background";
              };
            };

            # macOS defaults (tied to system.primaryUser)
            system.defaults = {
              NSGlobalDomain = {
                AppleShowAllExtensions = true;
                InitialKeyRepeat = 15;
                KeyRepeat = 2;
                NSAutomaticSpellingCorrectionEnabled = false;
              };
              dock = {
                autohide = true;
                show-recents = false;
              };
              finder = {
                AppleShowAllFiles = true;
                FXPreferredViewStyle = "clmv";
                ShowPathbar = true;
                ShowStatusBar = true;
              };
            };

            # Home Manager (user-level config)
            # Auto-backup any clobbered files like ~/.zshrc to *.pre-hm
            home-manager.backupFileExtension = "pre-hm";

            home-manager.users.${userName} = { pkgs, ... }: {
              home.stateVersion = "24.05";

              programs.git = {
                enable = true;
                userName = userName;
                userEmail = userEmail;
                extraConfig = {
                  pull.rebase = true;
                  credential.helper = "osxkeychain";
                };
              };

              programs.direnv = {
                enable = true;
                nix-direnv.enable = true;
              };

              programs.zsh = {
                enable = true;
                # new option (avoids deprecation warning)
                initContent = ''
                  alias ll="ls -lah"
                '';
              };

              home.shellAliases = {
                exo-dev = "nix develop -c uv run exo";
                exo-restart = "sudo launchctl kickstart -k system/org.nixos.exo-service";
              };
            };
          })

          # --- IP config LaunchDaemon (reads scripts/exo-config-ip.sh verbatim) ---
          (import ./modules/exo-config-ip.nix)

          # --- Repo sync LaunchDaemon (reads scripts/exo-repo-sync.sh verbatim) ---
          (import ./modules/exo-repo-sync.nix)

          # Per-host overrides
          ({ ... }: {
            # IP script defaults; override per host if needed
            launchd.daemons."exo-config-ip".serviceConfig.EnvironmentVariables = {
              WIFI_SERVICE = "Wi-Fi";
              LAN_PREFIX   = "192.168.1";
              NETMASK      = "255.255.255.0";
              # WIRED_SERVICE = "Thunderbolt Ethernet"; # optional pin
            };

            # Repo sync: run as the login user, log to their Library/Logs,
            # keep /opt/exo on latest origin/big-refactor via PAT in login keychain
            launchd.daemons."exo-repo-sync".serviceConfig = {
              UserName = userName;
              RunAtLoad = true;
              StartInterval = 900; # every 15 min
              StandardOutPath = "/Users/${userName}/Library/Logs/exo-repo-sync.log";
              StandardErrorPath = "/Users/${userName}/Library/Logs/exo-repo-sync.err";
              EnvironmentVariables = {
                EXO_REPO_URL_SSH   = "git@github.com:exo-explore/exo-v2.git";
                EXO_REPO_URL_HTTPS = "https://github.com/exo-explore/exo-v2.git";
                EXO_REPO_BRANCH    = "big-refactor";
                EXO_REPO_DEST      = "/opt/exo";
                EXO_REPO_OWNER     = userName;
                EXO_DEPLOY_KEY     = ""; # empty -> PAT/HTTPS path
              };
            };
          })
        ];
      };
  in {
    # ------- Define machines here -------

    # Mike's Mac Studio
    darwinConfigurations."mike" = mkHost {
      hostName = "mikes-mac-studio-1"; # ideally matches `scutil --get LocalHostName`
      userName = "mike";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
    };

    # Example second host (copy/adjust for your fleet)
    # darwinConfigurations."a1s-Mac-Studio" = mkHost {
    #   hostName = "a1s-Mac-Studio";
    #   userName = "a1";
    #   userEmail = "eng@exolabs.net";
    #   system   = "aarch64-darwin";
    # };
  };
}

