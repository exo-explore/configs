{
  description = "EXO macOS fleet via nix-darwin (+ Home Manager) with IP + repo sync daemons (SSH passwords allowed, multi-pubkey)";

  inputs = {
    nixpkgs.url       = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darwin.url        = "github:LnL7/nix-darwin";
    home-manager.url  = "github:nix-community/home-manager";
  };

  outputs = { self, nixpkgs, darwin, home-manager, ... }:
  let
    # mkHost supports multiple SSH pubkeys for the login user, and extra keys for other users.
    mkHost = {
      hostName,
      userName,
      userEmail ? "eng@exolabs.net",
      system   ? "aarch64-darwin",
      authorizedPubKeys ? [],                     # list of public key lines for ${userName}
      extraAuthorizedKeys ? {}                    # attrset: { "otheruser" = [ "ssh-ed25519 ...", ... ]; }
    }:
      darwin.lib.darwinSystem {
        inherit system;
        modules = [
          home-manager.darwinModules.home-manager

          ({ pkgs, lib, ... }: {
            # ----- required by nix-darwin -----
            system.stateVersion = 5;
            system.primaryUser  = userName;

            # share pkgs between HM and system
            home-manager.useGlobalPkgs   = true;
            home-manager.useUserPackages = true;

            networking.hostName = hostName;

            # ----- Nix -----
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

            # ----- base tools -----
            programs.zsh.enable = true;
            environment.systemPackages = with pkgs; [
              git uv direnv nix-direnv coreutils jq tmux htop
            ];

            # ensure local macOS user exists
            users.users.${userName} = {
              home = "/Users/${userName}";
              isHidden = false;
              shell = pkgs.zsh;
            };

            # ----- SSH (passwords allowed; also support /etc per-user authorized_keys) -----
            services.openssh = {
              enable = true;
              extraConfig = ''
                PermitRootLogin no
                PasswordAuthentication yes
                KbdInteractiveAuthentication yes
                UsePAM yes
                # hardening while keeping passwords on
                MaxAuthTries 3
                LoginGraceTime 30s
                MaxStartups 10:30:60
                PermitEmptyPasswords no
                # read per-user keys from /etc too
                AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 /etc/ssh/authorized_keys/%u
              '';
            };

            # Install authorized keys for the login user (can be multiple lines)
            environment.etc."ssh/authorized_keys/${userName}".text =
              lib.concatStringsSep "\n" authorizedPubKeys + "\n";

            # Extra users' authorized keys (optional)
            environment.etc = lib.mkMerge (
              lib.mapAttrsToList
                (uname: keys: {
                  name  = "ssh/authorized_keys/${uname}";
                  value = { text = lib.concatStringsSep "\n" keys + "\n"; };
                })
                extraAuthorizedKeys
            );

            # ----- sudo w/o password for admin (ops convenience) -----
            environment.etc."sudoers.d/10-admin-nopasswd".text = ''
              %admin ALL=(ALL) NOPASSWD: ALL
            '';

            # avoid pam symlink issues on some macOS
            environment.etc."pam.d/sudo_local".enable = lib.mkForce false;

            # ----- Tailscale -----
            services.tailscale.enable = true;

            # ----- power: stay awake -----
            system.activationScripts.power.text = ''
              /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1 || true
            '';

            # ----- best-effort sysctl (may be read-only) -----
            launchd.daemons."sysctl-tunables" = {
              command = ''${pkgs.bash}/bin/bash -lc '/usr/sbin/sysctl -w net.inet.tcp.msl=1000 || true' '';
              serviceConfig = { RunAtLoad = true; };
            };

            # ----- EXO service: run from cloned repo as user -----
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
                UserName = userName;                  # run as login user
                WorkingDirectory = "/opt/exo";        # run inside repo
                RunAtLoad = true;
                KeepAlive = true;
                StandardOutPath = "/var/log/exo.log";
                StandardErrorPath = "/var/log/exo.err";
                ProcessType = "Background";
                EnvironmentVariables = { PYTHONUNBUFFERED = "1"; };
              };
            };

            # ----- macOS defaults -----
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

            # ----- Home Manager (user) -----
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
                initContent = ''
                  alias ll="ls -lah"
                '';
              };

              home.shellAliases = {
                exo-dev     = "nix develop -c uv run exo";
                exo-restart = "sudo launchctl kickstart -k system/org.nixos.exo-service";
              };
            };
          })

          # --- IP config LaunchDaemon (reads scripts/exo-config-ip.sh) ---
          (import ./modules/exo-config-ip.nix)

          # --- Repo sync LaunchDaemon (reads scripts/exo-repo-sync.sh) ---
          (import ./modules/exo-repo-sync.nix)

          # --- per-host overrides ---
          ({ lib, ... }: {
            # IP config defaults (override per host if needed)
            launchd.daemons."exo-config-ip".serviceConfig.EnvironmentVariables = {
              WIFI_SERVICE = "Wi-Fi";
              LAN_PREFIX   = "192.168.1";
              NETMASK      = "255.255.255.0";
              # WIRED_SERVICE = "Thunderbolt Ethernet"; # optional pin
            };

            # Repo sync: run as user, log to user dir, keep /opt/exo on latest origin/big-refactor via PAT (System or login keychain)
            system.activationScripts.repoLogs.text = ''
              mkdir -p /Users/${userName}/Library/Logs
              chown ${userName}:staff /Users/${userName}/Library/Logs || true
            '';
            launchd.daemons."exo-repo-sync".serviceConfig = {
              UserName = userName;
              RunAtLoad = true;
              StartInterval = 900;  # every 15 min
              StandardOutPath  = lib.mkForce "/Users/${userName}/Library/Logs/exo-repo-sync.log";
              StandardErrorPath = lib.mkForce "/Users/${userName}/Library/Logs/exo-repo-sync.err";
              EnvironmentVariables = {
                EXO_REPO_URL_SSH   = "git@github.com:exo-explore/exo-v2.git";
                EXO_REPO_URL_HTTPS = "https://github.com/exo-explore/exo-v2.git";
                EXO_REPO_BRANCH    = "big-refactor";
                EXO_REPO_DEST      = "/opt/exo";
                EXO_REPO_OWNER     = userName;   # repo ownership
                EXO_DEPLOY_KEY     = "";         # empty -> PAT/HTTPS path used by script
              };
            };
          })
        ];
      };
  in {
    # ===== hosts =====
    darwinConfigurations."mike" = mkHost {
      hostName = "mikes-mac-studio-1";
      userName = "mike";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a4" = mkHost {
      hostName = "a4s-mac-studio";
      userName = "a4";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };

    # Copy/paste for the rest of the fleet; ensure the attr name matches your hosts file.
    # darwinConfigurations."a1" = mkHost { hostName = "a1s-Mac-Studio"; userName = "a1"; authorizedPubKeys = [ "ssh-ed25519 AAAA... key1" ]; };
  };
}

