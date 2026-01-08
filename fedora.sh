#!/bin/bash
# Fedora Development Environment Installation Script
# Installs all packages from the Dockerfile on a local Fedora system
# Includes Python, JavaScript, Node.js, Bun, and Astral uv

set -e  # Exit on any error

echo "=== Fedora Development Environment Installation ==="
echo "This script will install development tools and utilities."
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root or with sudo"
    exit 1
fi

# Update package lists
echo "[1/14] Updating package lists..."
dnf update -y
echo "Done."
echo

# Install Build Tools
echo "[2/14] Installing Build Tools..."
dnf install -y \
    gcc \
    gcc-c++ \
    make \
    cmake \
    clang \
    automake \
    autoconf \
    libtool \
    pkgconfig \
    gettext \
    patch
echo "Done."
echo

# Install Terminal Utilities
echo "[3/14] Installing Terminal Utilities..."
dnf install -y \
    tmux \
    htop \
    fzf \
    ripgrep \
    fd-find \
    neovim \
    bat \
    unzip
echo "Done."
echo

# Install Editors
echo "[4/14] Installing Editors..."
dnf install -y vim neovim
echo "Done."
echo

# Install Git Tools
echo "[5/14] Installing Git Tools..."
dnf install -y git git-lfs
git lfs install
echo "Done."
echo

# Install GitHub CLI
echo "[6/14] Installing GitHub CLI..."
dnf install -y dnf5-plugins
dnf config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
dnf install -y gh
echo "Done."
echo

# Install Lazygit
echo "[7/14] Installing Lazygit..."
LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
curl -Lo /tmp/lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
tar xf /tmp/lazygit.tar.gz -C /usr/local/bin lazygit
rm /tmp/lazygit.tar.gz
echo "Done."
echo

# Install Python and pipx with uv
echo "[8/14] Installing Python, pipx, and Astral uv..."
dnf install -y python3 python3-pip python3-virtualenv
python3 -m pip install --upgrade pipx

# Install Astral uv via pipx (recommended installation method)
pipx install uv

# Install additional Python tools
pipx install poetry
pipx install ruff
pipx ensurepath
echo "Done."
echo

# Install Node.js
echo "[9/14] Installing Node.js..."
dnf install -y nodejs npm
npm install -g yarn pnpm
echo "Done."
echo

# Install Bun
echo "[10/14] Installing Bun..."
# Install Bun via official installer script
curl -fsSL https://bun.sh/install | bash

# Determine the user to configure Bun PATH for
REAL_USER="${SUDO_USER:-$USER}"
USER_HOME=$(eval echo ~$REAL_USER)

if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    # Bun installs to ~/.bun/bin by default, add to .bashrc
    USER_BASHRC="$USER_HOME/.bashrc"
    grep -q ".bun/bin" "$USER_BASHRC" 2>/dev/null || cat >> "$USER_BASHRC" << 'EOF'

# Add Bun to PATH
export PATH="$HOME/.bun/bin:$PATH"
EOF
    echo "Bun PATH added to $USER_BASHRC"
fi
echo "Done."
echo

# Install Rust and Cargo tools
echo "[11/14] Installing Rust and Cargo tools..."
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo "WARNING: Installing Rust for root user. Recommended to run as a normal user with sudo."
    export HOME=/root
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --component rust-analyzer
    . $HOME/.cargo/env
    cargo install tree-sitter-cli
    cargo install eza
    cargo install zoxide
else
    # Install for the actual user
    sudo -u $REAL_USER bash -c 'curl --proto '"'"'https'"'"' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable --component rust-analyzer'
    sudo -u $REAL_USER bash -c '. ~/.cargo/env && cargo install tree-sitter-cli && cargo install eza && cargo install zoxide'
fi
echo "Done."
echo

# Install Flatpak and Obsidian
echo "[12/14] Installing Flatpak and Obsidian..."
if ! command -v flatpak &> /dev/null; then
    echo "Flatpak not found. Installing..."
    dnf install -y flatpak
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    echo "Flatpak installed."
else
    echo "Flatpak already installed."
fi

# Install Obsidian from Flatpak Hub
if ! flatpak list | grep -q "md.obsidian.Obsidian"; then
    echo "Installing Obsidian..."
    flatpak install -y flathub md.obsidian.Obsidian
    echo "Obsidian installed."
else
    echo "Obsidian already installed."
fi
echo "Done."
echo

# Install Snap
echo "[13/14] Installing Snap..."
if ! command -v snap &> /dev/null; then
    echo "Snap not found. Installing..."
    dnf install -y snapd
    systemctl enable --now snapd.socket
    ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
    echo "Snap installed."
else
    echo "Snap already installed."
fi
echo "Done."
echo

# # Install Yazi - dnf supports yazi - if it is ubuntu or other os - we use this instead
# echo "[14/14] Installing Yazi..."
# YAZI_VERSION=$(curl -s "https://api.github.com/repos/sxyazi/yazi/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
# curl -Lo /tmp/yazi.zip "https://github.com/sxyazi/yazi/releases/latest/download/yazi-x86_64-unknown-linux-gnu.zip"
# unzip -o /tmp/yazi.zip -d /tmp
# mv /tmp/yazi-x86_64-unknown-linux-gnu/yazi /usr/local/bin/
# mv /tmp/yazi-x86_64-unknown-linux-gnu/ya /usr/local/bin/
# rm -rf /tmp/yazi.zip /tmp/yazi-x86_64-unknown-linux-gnu
# echo "Done."
# echo

# Configure shell aliases and PATH for the user
echo "=== Configuring Shell ==="
if [ -n "$REAL_USER" ] && [ "$REAL_USER" != "root" ]; then
    USER_BASHRC="$USER_HOME/.bashrc"

    # Backup existing .bashrc
    [ -f "$USER_BASHRC" ] && cp "$USER_BASHRC" "${USER_BASHRC}.backup.$(date +%Y%m%d_%H%M%S)"

    # Add aliases if not already present
    grep -q "alias ls=\"eza\"" "$USER_BASHRC" 2>/dev/null || cat >> "$USER_BASHRC" << 'EOF'

# Development tool aliases
alias ls="eza"
alias ll="eza -la"
alias lt="eza --tree"
alias cat="bat"
alias vim="nvim"
eval "$(zoxide init bash)"

# Add local bin to PATH
export PATH="$HOME/.local/bin:$PATH"
EOF

    echo "Added aliases to $USER_BASHRC"
    echo "Please run: source ~/.bashrc"
else
    echo "Skipping shell configuration for root user."
    echo "Please manually add aliases to your user's ~/.bashrc:"
    echo ""
    echo "# Development tool aliases"
    echo "alias ls=\"eza\""
    echo "alias ll=\"eza -la\""
    echo "alias lt=\"eza --tree\""
    echo "alias cat=\"bat\""
    echo "alias vim=\"nvim\""
    echo "eval \"\$(zoxide init bash)\""
    echo "export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo "export PATH=\"\$HOME/.bun/bin:\$PATH\""
fi

echo
echo "=== Installation Complete ==="
echo
echo "Installed tools:"
echo "  Build: gcc, g++, make, cmake, clang, automake, autoconf, libtool"
echo "  Terminals: tmux, htop, fzf, ripgrep, fd-find, bat, unzip"
echo "  Editors: vim, neovim, Obsidian (via Flatpak)"
echo "  Git: git, git-lfs, lazygit, gh"
echo "  Python: python3, pip, pipx, uv (Astral), poetry, ruff"
echo "  JavaScript/Node.js: node, npm, yarn, pnpm"
echo "  Bun: bun (fast JavaScript runtime and package manager)"
echo "  Rust: rustup, cargo, rust-analyzer, tree-sitter-cli, eza, zoxide"
echo "  File Manager: yazi"
echo "  Package Managers: Flatpak, Snap"
echo
echo "Please restart your shell or run 'source ~/.bashrc' to use the new tools."
echo
