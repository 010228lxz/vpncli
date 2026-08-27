class Vpncli < Formula
  desc "Self-supervising VPN tunnel manager for openfortivpn or OpenVPN"
  homepage "https://github.com/010228lxz/vpncli"
  url "https://github.com/010228lxz/vpncli/archive/refs/tags/v0.1.16.tar.gz"
  sha256 "576a28dcd70ccfe96a2be97697e849666b660e50b22e8e122d5402ba1854d4bf"
  license "MIT"
  # Or track the default branch: brew install --HEAD 010228lxz/vpncli/vpncli
  head "https://github.com/010228lxz/vpncli.git", branch: "main"

  # The VPN backends are mutually exclusive at runtime. Keep both optional so
  # OpenVPN users do not receive the FortiVPN-only tools (and vice versa).
  depends_on "expect" => :optional
  depends_on "openfortivpn" => :optional

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
        - fortivpn: install its optional runtime dependencies:
                      brew install openfortivpn expect
        - openvpn: install its runtime dependency:
                      brew install openvpn

      Backend dependencies are optional in this formula so installing vpncli
      does not pull in an unrelated VPN client or password-prompt helper.

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
