class Vpncli < Formula
  desc "Self-supervising openfortivpn VPN tunnel manager (CLI + monitor daemon)"
  homepage "https://github.com/010228lxz/vpncli"
  # Release install: point url/sha256 at a tagged tarball, e.g.
  #   url "https://github.com/010228lxz/vpncli/archive/refs/tags/v0.1.0.tar.gz"
  #   sha256 "..."
  # Until then, install straight from the default branch with --HEAD:
  #   brew install --HEAD 010228lxz/vpncli/vpncli
  head "https://github.com/010228lxz/vpncli.git", branch: "main"
  license "MIT"

  depends_on "openfortivpn"
  depends_on "expect"

  def install
    bin.install "bin/vpnctl"
    libexec.install "libexec/fortiVPN.expect"
    pkgshare.install "share/vpn.conf.example", "share/vpncli.sudoers.template"
  end

  def caveats
    <<~EOS
      Homebrew can't write your secret store or /etc/sudoers.d, so finish setup
      on this machine with:

        vpnctl setup

      That creates the config, stores your VPN password, and installs the
      passwordless-sudo rule scoped to your exact openfortivpn command.

      Config lives in ~/.config/vpncli/ and logs/pid in ~/.local/state/vpncli/.
    EOS
  end

  test do
    # --help exits non-zero (usage), so capture with the expected status.
    assert_match "Usage:", shell_output("#{bin}/vpnctl --help", 1)
  end
end
