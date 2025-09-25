# modules/exo-auto-login.nix
# Usage from flake: (import ./modules/exo-auto-login.nix { autoLoginUser = userName; })
{ autoLoginUser ? null, keychainService ? "exo-autologin-pass", requireFileVaultOff ? true }:
{ lib, pkgs, ... }:

let
  script = pkgs.writeShellScript "enable-autologin" ''
    set -euo pipefail

    USER="${autoLoginUser:-}"
    [ -n "$USER" ] || { echo "auto-login: no user provided"; exit 0; }

    # 1) FileVault guard
    if ${lib.boolToString requireFileVaultOff}; then
      if /usr/bin/fdesetup status | /usr/bin/grep -q "On"; then
        echo "auto-login: FileVault is ON → refusing to enable (disable FV and rebuild)."
        exit 0
      fi
    fi

    # 2) Resolve password from System keychain or env
    PW="$(/usr/bin/security find-generic-password -s "${keychainService}-${USER}" -w /Library/Keychains/System.keychain 2>/dev/null || true)"
    if [ -z "$PW" ] && [ -n "${AUTOLOGIN_PASS:-}" ]; then
      PW="$AUTOLOGIN_PASS"
    fi
    if [ -z "$PW" ]; then
      echo "auto-login: no password found in System keychain (service='${keychainService}-${USER}') and AUTOLOGIN_PASS not set → skipping."
      exit 0
    fi

    # 3) Write /Library/Preferences/com.apple.loginwindow autoLoginUser
    /usr/bin/defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser -string "$USER" || true

    # 4) Generate /etc/kcpassword (Apple’s XOR scheme)
    /usr/bin/python3 - "$PW" <<'PY' | /usr/bin/tee /etc/kcpassword >/dev/null
import sys
pw = sys.argv[1]
key = bytes([0x7D,0x89,0x52,0x23,0xD2,0xBC,0xDD,0xEA,0xA3,0xB9,0x1F])
data = (pw + '\x00').encode('utf-8')
while len(data) % 12 != 0:
    data += b'\x00'
out = bytes([b ^ key[i % len(key)] for i,b in enumerate(data)])
sys.stdout.buffer.write(out)
PY

    /usr/sbin/chown root:wheel /etc/kcpassword
    /bin/chmod 0600 /etc/kcpassword

    echo "auto-login: configured for user '$USER'. Reboot required."
  '';
in
{
  system.activationScripts.enableAutoLogin.text = ''
    ${script}
  '';
}

