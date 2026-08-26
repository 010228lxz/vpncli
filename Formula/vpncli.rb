class Vpncli < Formula
  desc "Self-supervising VPN tunnel manager for openfortivpn or OpenVPN"
  homepage "https://github.com/010228lxz/vpncli"
  url "https://github.com/010228lxz/vpncli/archive/refs/tags/v0.1.5.tar.gz"
  sha256 "fad44db7cf931b57a6ed804a6433687d67645692978e6c9bf68a51248b215ef5"
  license "MIT"
  # Or track the default branch: brew install --HEAD 010228lxz/vpncli/vpncli
  head "https://github.com/010228lxz/vpncli.git", branch: "main"

  depends_on "expect"
  depends_on "openfortivpn"

  def install
    bin.install "bin/vpnctl"
    libexec.install "libexec/fortiVPN.expect", "libexec/vpnctl-helper"
    pkgshare.install "share/vpn.conf.example", "share/vpn.ovpn.example",
                      "share/vpncli.sudoers.template", "share/vpncli-openvpn.sudoers.template"
  end

  def caveats
    <<~EOS
      Homebrew can't write your secret store or /etc/sudoers.d, so finish setup
      on this machine with:

        vpnctl setup

      That creates the config, stores your VPN password, and installs the
      passwordless-sudo rule scoped to your exact launch command.

      Two backends are supported, chosen via VPN_TYPE in
      ~/.config/vpncli/settings (default: fortivpn):
        - fortivpn: needs `openfortivpn` (installed as a dependency above).
        - openvpn:  needs `openvpn` too — install it yourself:
                      brew install openvpn

      This formula installs the fortivpn backend and its `expect` helper as
      baseline dependencies. OpenVPN users will have those extra packages
      installed, but do not need to use them.

      Config lives in ~/.config/vpncli/ and logs/pid in ~/.local/state/vpncli/.
      For passwordless sudo, Homebrew's user-owned OpenVPN and vpnctl-helper
      must be copied to a root-owned path. See the README security instructions
      before running `vpnctl install-sudoers`.
    EOS
  end

  test do
    # --help exits non-zero (usage), so capture with the expected status.
    assert_match "Usage:", shell_output("#{bin}/vpnctl --help", 1)
  end
end
