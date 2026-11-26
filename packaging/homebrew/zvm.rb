class Zvm < Formula
  desc "Fast, zero-dependency Zig version manager written in Zig"
  homepage "https://github.com/Judeadeniji/zvm"
  version "0.1.0"
  license "MIT"

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/Judeadeniji/zvm/releases/download/v#{version}/zvm-v#{version}-aarch64-macos.tar.gz"
    else
      url "https://github.com/Judeadeniji/zvm/releases/download/v#{version}/zvm-v#{version}-x86_64-macos.tar.gz"
    end
  end

  on_linux do
    if Hardware::CPU.arm?
      url "https://github.com/Judeadeniji/zvm/releases/download/v#{version}/zvm-v#{version}-aarch64-linux.tar.gz"
    else
      url "https://github.com/Judeadeniji/zvm/releases/download/v#{version}/zvm-v#{version}-x86_64-linux.tar.gz"
    end
  end

  def install
    bin.install "zvm"
  end

  def caveats
    <<~EOS
      To finish setup, create the zig/zls shims and add ~/.zvm/bin to your PATH:
        zvm setup
        eval "$(zvm env zsh)"
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/zvm --version")
  end
end
