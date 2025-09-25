{ lib, pkgs, ... }:

# Enables macOS Screen Sharing (com.apple.screensharing) and lets specified
# users or groups connect. Defaults to admin group if none supplied.
#
# Usage in flake.nix:
#   (import ./modules/exo-screen-sharing.nix {
#     usersAllowed = [ "a1" "a2" ];          # optional: allow specific users
#     groupsAllowed = [ "admin" ];           # optional: allow groups
#   })

{ usersAllowed ? [ ], groupsAllowed ? [ "admin" ] }:

let
  mkDsCmds = ''
    set -e

    # 1) Load and enable the built-in Screen Sharing daemon
    /bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist || true

    # 2) Ensure the access group exists: com.apple.access_screensharing
    if ! /usr/sbin/dscl . -read /Groups/com.apple.access_screensharing >/dev/null 2>&1; then
      /usr/sbin/dseditgroup -o create -n /Local/Default com.apple.access_screensharing
      /usr/sbin/dscl . -create /Groups/com.apple.access_screensharing RealName "Screen Sharing Access"
    fi

    # 3) Add allowed local users
  '' + (lib.concatStringsSep "\n" (map (u: ''
    /usr/sbin/dseditgroup -o edit -a ${u} -t user com.apple.access_screensharing || true
  '') usersAllowed))
  + "\n"
  + (lib.concatStringsSep "\n" (map (g: ''
    /usr/sbin/dseditgroup -o edit -a ${g} -t group com.apple.access_screensharing || true
  '') groupsAllowed))
  + ''

    # 4) (Optional) Disallow “all users” fallback, we only want our group list
    /usr/bin/defaults write /Library/Preferences/com.apple.RemoteManagement ScreenSharingReqPerm -bool true || true

    # 5) Make sure the service is up
    /bin/launchctl kickstart -k system/com.apple.screensharing || true
  '';
in
{
  # Run once at each activation
  system.activationScripts.enableScreenSharing.text = mkDsCmds;

  # Nice to have: advertise VNC port to localhost/Tailscale only (no firewall change here).
  # If you want the macOS firewall to allow inbound automatically, add:
  # services.tailscale.enable = true;  # you already have this
}

