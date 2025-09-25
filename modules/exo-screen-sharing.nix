# modules/exo-screen-sharing.nix
# Curried module:
#   (import ./modules/exo-screen-sharing.nix { usersAllowed = [ "a1" ]; groupsAllowed = [ "admin" ]; })
# returns a proper nix-darwin module taking { lib, pkgs, ... }.

{ usersAllowed ? [ ], groupsAllowed ? [ "admin" ] }:
{ lib, pkgs, ... }:

let
  mkDsCmds =
    ''
      set -e

      # 1) Load & enable Screen Sharing daemon
      /bin/launchctl load -w /System/Library/LaunchDaemons/com.apple.screensharing.plist || true

      # 2) Ensure access group exists
      if ! /usr/sbin/dscl . -read /Groups/com.apple.access_screensharing >/dev/null 2>&1; then
        /usr/sbin/dseditgroup -o create -n /Local/Default com.apple.access_screensharing
        /usr/sbin/dscl . -create /Groups/com.apple.access_screensharing RealName "Screen Sharing Access"
      fi
    ''
    + (lib.concatStringsSep "\n" (map (u: ''
        /usr/sbin/dseditgroup -o edit -a ${u} -t user com.apple.access_screensharing || true
      '') usersAllowed))
    + "\n"
    + (lib.concatStringsSep "\n" (map (g: ''
        /usr/sbin/dseditgroup -o edit -a ${g} -t group com.apple.access_screensharing || true
      '') groupsAllowed))
    + ''
      # 3) Require explicit permission (no “all users” fallback)
      /usr/bin/defaults write /Library/Preferences/com.apple.RemoteManagement ScreenSharingReqPerm -bool true || true

      # 4) Make sure service is up
      /bin/launchctl kickstart -k system/com.apple.screensharing || true
    '';
in
{
  system.activationScripts.enableScreenSharing.text = mkDsCmds;
}
