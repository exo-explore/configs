{
  description = "EXO macOS fleet via nix-darwin (+ Home Manager) with IP + repo sync daemons (SSH passwords allowed, multi-pubkey)";

  inputs = {
    nixpkgs.url      = "github:NixOS/nixpkgs/nixpkgs-unstable";
    darwin.url       = "github:LnL7/nix-darwin";
    home-manager.url = "github:nix-community/home-manager";
  };

  outputs = { self, nixpkgs, darwin, home-manager, ... }:
  let
    mkHost = {
      hostName,
      userName,
      userEmail ? "eng@exolabs.net",
      system   ? "aarch64-darwin",
      authorizedPubKeys ? [],
      extraAuthorizedKeys ? {}
    }:
      darwin.lib.darwinSystem {
        inherit system;
        modules = [
          home-manager.darwinModules.home-manager

          ({ pkgs, lib, ... }: {
            # ----- nix-darwin base -----
            system.stateVersion = 5;
            system.primaryUser  = userName;

            home-manager.useGlobalPkgs   = true;
            home-manager.useUserPackages = true;

            networking.hostName = hostName;

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

            programs.zsh.enable = true;
            environment.systemPackages = with pkgs; [
              git uv direnv nix-direnv coreutils jq tmux htop
            ];

            users.users.${userName} = {
              home = "/Users/${userName}";
              isHidden = false;
              shell = pkgs.zsh;
            };

            # ----- SSH (password login allowed) -----
            services.openssh = {
              enable = true;
              extraConfig = ''
                PermitRootLogin no
                PasswordAuthentication yes
                KbdInteractiveAuthentication yes
                UsePAM yes
                MaxAuthTries 3
                LoginGraceTime 30s
                MaxStartups 10:30:60
                PermitEmptyPasswords no
                AuthorizedKeysFile .ssh/authorized_keys .ssh/authorized_keys2 /etc/ssh/authorized_keys/%u
              '';
            };

            # /etc entries (+ extra per-user authorized_keys)
            environment.etc = lib.mkMerge [
              {
                "ssh/authorized_keys/${userName}".text = lib.concatStringsSep "\n" authorizedPubKeys + "\n";
                "sudoers.d/10-admin-nopasswd".text = ''
                  %admin ALL=(ALL) NOPASSWD: ALL
                '';
                "pam.d/sudo_local".enable = lib.mkForce false;
              }
              (lib.listToAttrs (
                lib.mapAttrsToList
                  (uname: keys: {
                    name  = "ssh/authorized_keys/${uname}";
                    value = { text = lib.concatStringsSep "\n" keys + "\n"; };
                  })
                  extraAuthorizedKeys
              ))
            ];

            system.activationScripts.migrateEtcAuthorizedKeys.text =
              (let users = [ userName ] ++ (builtins.attrNames extraAuthorizedKeys);
               in ''
                 /bin/mkdir -p /etc/ssh/authorized_keys
                 for u in ${lib.concatStringsSep " " users}; do
                   f="/etc/ssh/authorized_keys/$u"
                   if [ -e "$f" ] && [ ! -L "$f" ]; then
                     /bin/mv "$f" "$f.before-nix-darwin" || true
                   fi
                 done
               '');

            services.tailscale.enable = true;

            # Stay awake
            system.activationScripts.power.text = ''
              /usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 >/dev/null 2>&1 || true
            '';

            # Migrate common /etc files once
            system.activationScripts.migrateEtcBase.text = ''
              for f in /etc/nix/nix.conf /etc/bashrc /etc/zshrc; do
                if [ -e "$f" ] && [ ! -L "$f" ]; then
                  /bin/mv "$f" "$f.before-nix-darwin" || true
                fi
              done
            '';

            # Example tunable
            launchd.daemons."sysctl-tunables" = {
              command = ''${pkgs.bash}/bin/bash -lc '/usr/sbin/sysctl -w net.inet.tcp.msl=1000 || true' '';
              serviceConfig = { RunAtLoad = true; };
            };

            # ----- EXO: ensure dirs, logs, wrapper -----
            system.activationScripts.exoRunner.text = ''
              LOG_DIR="/Users/${userName}/Library/Logs"
              LOG_OUT="$LOG_DIR/exo.log"
              LOG_ERR="$LOG_DIR/exo.err"

              /bin/mkdir -p /opt/exo
              /usr/sbin/chown -R ${userName}:staff /opt/exo || true

              /bin/mkdir -p "$LOG_DIR"
              /usr/sbin/chown ${userName}:staff "$LOG_DIR" || true
              /usr/bin/touch "$LOG_OUT" "$LOG_ERR"
              /usr/sbin/chown ${userName}:staff "$LOG_OUT" "$LOG_ERR" || true

              cat > /opt/exo/.run-exo.sh <<'SH'
              #!/usr/bin/env bash
              set -euo pipefail
              echo "[$(date -u +%FT%TZ)] starting exo via nix develop + uv run exo" >&2
              cd /opt/exo
              export EXO_NONINTERACTIVE=1
              export TERM=dumb
              export PYTHONUNBUFFERED=1
              exec nix develop . \
                --accept-flake-config \
                --extra-experimental-features "nix-command flakes" \
                --command uv run exo
              SH
              /bin/chmod +x /opt/exo/.run-exo.sh
            '';

            # ----- Auto-start EXO as a LaunchAgent (user domain) -----
            launchd.agents."org.nixos.exo-service" = {
              command = "${pkgs.bash}/bin/bash -lc '/opt/exo/.run-exo.sh'";
              serviceConfig = {
                RunAtLoad = true;
                KeepAlive = true;
                WorkingDirectory = "/opt/exo";
                StandardOutPath = "/Users/${userName}/Library/Logs/exo.log";
                StandardErrorPath = "/Users/${userName}/Library/Logs/exo.err";
                ProcessType = "Background";
                EnvironmentVariables = {
                  PYTHONUNBUFFERED = "1";
                  TERM = "dumb";
                  EXO_NONINTERACTIVE = "1";
                };
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
                exo-restart = "launchctl kickstart -k gui/$(id -u)/org.nixos.exo-service";
              };
            };
          })

          # --- EXO modules you already use ---
          (import ./modules/exo-config-ip.nix)
          (import ./modules/exo-repo-sync.nix)

          # --- Per-host overrides ---
          ({ lib, ... }: {
            launchd.daemons."exo-config-ip".serviceConfig.EnvironmentVariables = {
              WIFI_SERVICE = "Wi-Fi";
              LAN_PREFIX   = "192.168.1";
              NETMASK      = "255.255.255.0";
              # WIRED_SERVICE = "Thunderbolt Ethernet";
            };

            # Repo sync as user -> /opt/exo
            system.activationScripts.repoLogs.text = ''
              mkdir -p /Users/${userName}/Library/Logs
              chown ${userName}:staff /Users/${userName}/Library/Logs || true
            '';
            launchd.daemons."exo-repo-sync".serviceConfig = {
              UserName = userName;
              RunAtLoad = true;
              StartInterval = 900;
              StandardOutPath  = lib.mkForce "/Users/${userName}/Library/Logs/exo-repo-sync.log";
              StandardErrorPath = lib.mkForce "/Users/${userName}/Library/Logs/exo-repo-sync.err";
              EnvironmentVariables = {
                EXO_REPO_URL_SSH   = "git@github.com:exo-explore/exo-v2.git";
                EXO_REPO_URL_HTTPS = "https://github.com/exo-explore/exo-v2.git";
                EXO_REPO_BRANCH    = "big-refactor";
                EXO_REPO_DEST      = "/opt/exo";
                EXO_REPO_OWNER     = userName;
                EXO_DEPLOY_KEY     = "";
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
    darwinConfigurations."a1" = mkHost {
      hostName = "a1s-mac-studio";
      userName = "a1";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a2" = mkHost {
      hostName = "a2s-mac-studio";
      userName = "a2";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a3" = mkHost {
      hostName = "a3s-mac-studio";
      userName = "a3";
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
    darwinConfigurations."a5" = mkHost {
      hostName = "a5s-mac-studio";
      userName = "a5";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a6" = mkHost {
      hostName = "a6s-mac-studio";
      userName = "a6";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a7" = mkHost {
      hostName = "a7s-mac-studio";
      userName = "a7";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a8" = mkHost {
      hostName = "a8s-mac-studio";
      userName = "a8";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a9" = mkHost {
      hostName = "a9s-mac-studio";
      userName = "a9";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a10" = mkHost {
      hostName = "a10s-mac-studio";
      userName = "a10";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a11" = mkHost {
      hostName = "a11s-mac-studio";
      userName = "a11";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
    darwinConfigurations."a12" = mkHost {
      hostName = "a12s-mac-studio";
      userName = "a12";
      userEmail = "eng@exolabs.net";
      system   = "aarch64-darwin";
      authorizedPubKeys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMPRB5fd0UnQKnBwtZ+WWNy6smS14AoHVMjzLARenI/O garyexo@outlook.com"
      ];
    };
  };
}
