#!/bin/bash
# Fedora Development Environment Installation Script
# Installs all packages from the Dockerfile on a local Fedora system
# Includes Python, JavaScript, Node.js, Bun, and Astral uv

set -Eeuo pipefail

NETWORK_TIMEOUT_SECONDS="${NETWORK_TIMEOUT_SECONDS:-120}"
PACKAGE_TIMEOUT_SECONDS="${PACKAGE_TIMEOUT_SECONDS:-1200}"
INSTALLER_TIMEOUT_SECONDS="${INSTALLER_TIMEOUT_SECONDS:-1200}"
NETWORK_RETRY_COUNT="${NETWORK_RETRY_COUNT:-3}"
PACKAGE_RETRY_COUNT="${PACKAGE_RETRY_COUNT:-3}"
INSTALLER_RETRY_COUNT="${INSTALLER_RETRY_COUNT:-3}"
RETRY_BACKOFF_SECONDS="${RETRY_BACKOFF_SECONDS:-5,15,30}"

declare -a RETRY_BACKOFF_VALUES=()
IFS=',' read -r -a RETRY_BACKOFF_VALUES <<< "${RETRY_BACKOFF_SECONDS}"
declare -ar DNF_NONINTERACTIVE_FLAGS=(--assumeyes)
declare -ar DNF_INSTALL_FLAGS=(--setopt=install_weak_deps=False)

REAL_USER=""
USER_HOME=""
BASHRC_BACKUP_DONE="false"

readonly BASHRC_MARKER_PREFIX="### Fedora one-shot bootstrap shell block"

resolve_user_home() {
    local user="$1"
    local home_dir=""

    if ! getent passwd "${user}" >/dev/null 2>&1; then
        return 1
    fi

    home_dir="$(getent passwd "${user}" | awk -F: '{print $6}')"
    if [ -z "${home_dir}" ] || [ ! -d "${home_dir}" ]; then
        return 1
    fi

    printf '%s\n' "${home_dir}"
}

timestamp() {
    date +"%Y-%m-%dT%H:%M:%S%z"
}

log() {
    local level="$1"
    shift
    printf '[%s] [%s] %s\n' "$(timestamp)" "${level}" "$*"
}

on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    local command="${BASH_COMMAND:-unknown}"
    log "ERROR" "Unhandled failure line=${line_no} exit=${exit_code} cmd=${command}"
}

trap on_error ERR

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        log "ERROR" "Please run as root or with sudo"
        exit 1
    fi
}

initialize_user_context() {
    local candidate=""
    local resolved_home=""

    for candidate in "${SUDO_USER:-}" "${USER:-}"; do
        [ -z "${candidate}" ] && continue

        if resolved_home="$(resolve_user_home "${candidate}")"; then
            REAL_USER="${candidate}"
            USER_HOME="${resolved_home}"
            log "INFO" "Resolved user context as ${REAL_USER} (${USER_HOME})"
            return 0
        fi
    done

    if resolved_home="$(resolve_user_home root)"; then
        REAL_USER="root"
        USER_HOME="${resolved_home}"
        log "WARN" "Could not resolve sudo/user context; defaulting to root"
        return 0
    fi

    REAL_USER="${USER:-root}"
    USER_HOME="${HOME:-/root}"
    log "WARN" "Could not resolve user home from passwd; falling back to ${USER_HOME}"
    return 1
}

backup_user_bashrc_if_needed() {
    local user_bashrc="$1"

    if [ "${BASHRC_BACKUP_DONE}" = "true" ]; then
        return 0
    fi

    if [ -f "${user_bashrc}" ]; then
        if ! cp -f "${user_bashrc}" "${user_bashrc}.backup.$(date +%Y%m%d_%H%M%S)"; then
            log "WARN" "Failed to backup ${user_bashrc}; continuing anyway"
            return 0
        fi
        BASHRC_BACKUP_DONE="true"
        log "INFO" "Backed up ${user_bashrc}"
    fi
}

append_bashrc_block_if_missing() {
    local user_bashrc="$1"
    local block_id="$2"
    local block_content="$3"

    local marker_start="${BASHRC_MARKER_PREFIX} [${block_id}] START"
    local marker_end="${BASHRC_MARKER_PREFIX} [${block_id}] END"
    local bashrc_dir
    bashrc_dir="$(dirname "${user_bashrc}")"

    if [ -e "${user_bashrc}" ] && [ ! -f "${user_bashrc}" ]; then
        log "ERROR" "Unsupported .bashrc path type: ${user_bashrc}"
        return 1
    fi

    if ! [ -f "${user_bashrc}" ]; then
        if [ ! -w "${bashrc_dir}" ]; then
            log "WARN" "Cannot create ${user_bashrc}: directory is not writable"
            return 0
        fi

        : > "${user_bashrc}" || {
            log "WARN" "Cannot create ${user_bashrc}; skipping shell configuration"
            return 0
        }
    elif [ ! -w "${user_bashrc}" ]; then
        log "WARN" "Cannot modify ${user_bashrc}; skipping shell configuration"
        return 0
    fi

    if grep -qF "${marker_start}" "${user_bashrc}"; then
        log "INFO" "Marker block already present in ${user_bashrc}: ${block_id}"
        return 0
    fi

    backup_user_bashrc_if_needed "${user_bashrc}"

    printf '\n%s\n%s\n%s\n' "${marker_start}" "${block_content}" "${marker_end}" >> "${user_bashrc}" || {
        log "WARN" "Failed writing shell block to ${user_bashrc}; skipping"
        return 0
    }

    log "INFO" "Added marker-controlled shell block (${block_id}) to ${user_bashrc}"
}

run_with_timeout() {
    local timeout_seconds="$1"
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout --preserve-status --kill-after=15s "${timeout_seconds}s" "$@"
    else
        "$@"
    fi
}

get_backoff_delay() {
    local attempt="$1"
    local idx=$((attempt - 1))
    local last_idx=$(( ${#RETRY_BACKOFF_VALUES[@]} - 1 ))

    if (( last_idx < 0 )); then
        echo 5
        return
    fi

    if (( idx > last_idx )); then
        idx=${last_idx}
    fi

    echo "${RETRY_BACKOFF_VALUES[idx]}"
}

run_with_retry() {
    local retries="$1"
    local timeout_seconds="$2"
    shift 2

    local attempt=1
    local exit_code=0

    while (( attempt <= retries )); do
        if run_with_timeout "${timeout_seconds}" "$@"; then
            return 0
        fi

        exit_code=$?

        if (( attempt == retries )); then
            log "ERROR" "Command failed after ${attempt} attempt(s): $* (exit=${exit_code})"
            return "${exit_code}"
        fi

        local delay
        delay="$(get_backoff_delay "${attempt}")"
        log "WARN" "Command failed (attempt ${attempt}/${retries}, exit=${exit_code}); retrying in ${delay}s: $*"
        sleep "${delay}"
        ((attempt++))
    done

    return "${exit_code}"
}

run_network_cmd() {
    run_with_retry "${NETWORK_RETRY_COUNT}" "${NETWORK_TIMEOUT_SECONDS}" "$@"
}

run_package_cmd() {
    run_with_retry "${PACKAGE_RETRY_COUNT}" "${PACKAGE_TIMEOUT_SECONDS}" "$@"
}

is_dnf_lock_contention_output() {
    local output="$1"

    case "${output}" in
        *"waiting for process with pid"*|*"Another app is currently holding the dnf lock"*|*"Could not get lock"*|*"Failed to obtain the transaction lock"*)
            return 0
            ;;
    esac

    return 1
}

run_dnf_cmd() {
    local -a cmd=(dnf "${DNF_NONINTERACTIVE_FLAGS[@]}" "$@")
    local attempt=1
    local exit_code=0
    local output=""

    while (( attempt <= PACKAGE_RETRY_COUNT )); do
        if output="$(run_with_timeout "${PACKAGE_TIMEOUT_SECONDS}" "${cmd[@]}" 2>&1)"; then
            if [ -n "${output}" ]; then
                printf '%s\n' "${output}"
            fi
            return 0
        fi

        exit_code=$?

        if [ -n "${output}" ]; then
            printf '%s\n' "${output}" >&2
        fi

        if (( attempt == PACKAGE_RETRY_COUNT )); then
            log "ERROR" "DNF command failed after ${attempt} attempt(s): ${cmd[*]} (exit=${exit_code})"
            return "${exit_code}"
        fi

        local delay
        delay="$(get_backoff_delay "${attempt}")"

        if is_dnf_lock_contention_output "${output}"; then
            log "WARN" "DNF lock contention detected (attempt ${attempt}/${PACKAGE_RETRY_COUNT}, exit=${exit_code}); retrying in ${delay}s: ${cmd[*]}"
        else
            log "WARN" "DNF command failed (attempt ${attempt}/${PACKAGE_RETRY_COUNT}, exit=${exit_code}); retrying in ${delay}s: ${cmd[*]}"
        fi

        sleep "${delay}"
        ((attempt++))
    done

    return "${exit_code}"
}

run_installer_cmd() {
    run_with_retry "${INSTALLER_RETRY_COUNT}" "${INSTALLER_TIMEOUT_SECONDS}" "$@"
}

require_x86_64_artifact() {
    local artifact_name="$1"
    local current_arch
    current_arch="$(uname -m)"

    if [ "${current_arch}" != "x86_64" ]; then
        log "ERROR" "${artifact_name} currently supports x86_64 artifacts only (detected ${current_arch})"
        return 1
    fi
}

download_installer_script() {
    local url="$1"
    local script_path="$2"
    local installer_name="$3"
    local validation_pattern="$4"

    run_network_cmd curl --proto "=https" --tlsv1.2 -fsSL -o "${script_path}" "${url}"

    if [ ! -s "${script_path}" ]; then
        log "ERROR" "${installer_name} installer download is empty"
        rm -f "${script_path}"
        return 1
    fi

    if [ -n "${validation_pattern}" ] && ! grep -Eq "${validation_pattern}" "${script_path}"; then
        log "ERROR" "${installer_name} installer validation failed"
        rm -f "${script_path}"
        return 1
    fi
}

install_root_cargo_crate_if_missing() {
    local binary_name="$1"
    local crate_name="$2"
    local cargo_binary_path
    cargo_binary_path="${HOME}/.cargo/bin/${binary_name}"

    if [ -x "${cargo_binary_path}" ]; then
        log "INFO" "Cargo binary ${binary_name} already installed at ${cargo_binary_path}; skipping"
        return 0
    fi

    run_installer_cmd cargo install "${crate_name}"
}

install_user_cargo_crate_if_missing() {
    local binary_name="$1"
    local crate_name="$2"
    local cargo_binary_path
    cargo_binary_path="${USER_HOME}/.cargo/bin/${binary_name}"

    if [ -x "${cargo_binary_path}" ]; then
        log "INFO" "Cargo binary ${binary_name} already installed at ${cargo_binary_path}; skipping"
        return 0
    fi

    run_installer_cmd sudo -u "${REAL_USER}" bash -lc ". \"\$HOME/.cargo/env\" && cargo install \"\$1\"" _ "${crate_name}"
}

run_step() {
    local step_label="$1"
    local mode="$2"
    shift 2

    log "INFO" "${step_label} START mode=${mode}"

    if "$@"; then
        log "INFO" "${step_label} DONE"
        return 0
    fi

    local exit_code=$?
    if [ "${mode}" = "optional" ]; then
        log "WARN" "${step_label} FAILED mode=optional exit=${exit_code}; continuing"
        return 0
    fi

    log "ERROR" "${step_label} FAILED mode=critical exit=${exit_code}"
    return "${exit_code}"
}

step_update_package_lists() {
    run_dnf_cmd update
}

step_install_build_tools() {
    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" \
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
}

step_install_terminal_utilities() {
    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" \
        tmux \
        htop \
        fzf \
        ripgrep \
        fd-find \
        neovim \
        bat \
        unzip
}

step_install_editors() {
    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" vim neovim
}

step_install_git_tools() {
    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" git git-lfs
    run_installer_cmd git lfs install
}

step_install_github_cli() {
    local gh_repo_file="/etc/yum.repos.d/gh-cli.repo"

    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" dnf5-plugins

    if [ -f "${gh_repo_file}" ]; then
        log "INFO" "GitHub CLI repo already configured at ${gh_repo_file}"
    else
        run_dnf_cmd config-manager addrepo --from-repofile=https://cli.github.com/packages/rpm/gh-cli.repo
    fi

    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" gh
}

step_install_lazygit() {
    local release_json
    local lazygit_version
    local lazygit_archive_path="/tmp/lazygit.tar.gz"

    release_json="$(run_network_cmd curl -fsSL "https://api.github.com/repos/jesseduffield/lazygit/releases/latest")"

    if [[ "${release_json}" =~ \"tag_name\"[[:space:]]*:[[:space:]]*\"v([^\"]+)\" ]]; then
        lazygit_version="${BASH_REMATCH[1]}"
    else
        lazygit_version=""
    fi

    if [[ -z "${lazygit_version}" ]] || [[ ! "${lazygit_version}" =~ ^[0-9]+(\.[0-9]+){1,3}([-.][0-9A-Za-z]+)*$ ]]; then
        log "ERROR" "lazygit version missing or invalid in release metadata"
        return 1
    fi

    require_x86_64_artifact "lazygit release archive" || return 1

    run_network_cmd curl -fL -o "${lazygit_archive_path}" "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${lazygit_version}_Linux_x86_64.tar.gz"

    if [ ! -s "${lazygit_archive_path}" ]; then
        log "ERROR" "Downloaded lazygit archive is empty"
        rm -f "${lazygit_archive_path}"
        return 1
    fi

    if ! tar tf "${lazygit_archive_path}" lazygit >/dev/null 2>&1; then
        log "ERROR" "Downloaded lazygit archive failed validation"
        rm -f "${lazygit_archive_path}"
        return 1
    fi

    run_installer_cmd tar xf "${lazygit_archive_path}" -C /usr/local/bin lazygit
    rm -f "${lazygit_archive_path}"
}

step_install_python_tools() {
    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" python3 python3-pip python3-virtualenv
    run_installer_cmd python3 -m pip install --upgrade pipx
    run_installer_cmd pipx install uv
    run_installer_cmd pipx install poetry
    run_installer_cmd pipx install ruff
    log "INFO" "Skipping pipx ensurepath; shell configuration handles ~/.local/bin in PATH."
}

step_install_node() {
    run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" nodejs npm
    run_installer_cmd npm install -g yarn pnpm
}

step_install_bun() {
    local bun_installer
    bun_installer="$(mktemp /tmp/bun-install.XXXXXX.sh)"

    download_installer_script "https://bun.sh/install" "${bun_installer}" "bun" 'Bun|bun' || return 1

    if ! run_installer_cmd bash "${bun_installer}"; then
        local exit_code=$?
        rm -f "${bun_installer}"
        return "${exit_code}"
    fi

    rm -f "${bun_installer}"

    if [ -n "${REAL_USER}" ] && [ "${REAL_USER}" != "root" ]; then
        append_bashrc_block_if_missing "${USER_HOME}/.bashrc" "bun" \
            "# Add Bun to PATH
export PATH=\"\$HOME/.bun/bin:\$PATH\""
    fi
}

step_install_rust_tools() {
    local rustup_installer
    rustup_installer="$(mktemp /tmp/rustup-install.XXXXXX.sh)"

    download_installer_script "https://sh.rustup.rs" "${rustup_installer}" "rustup" 'rustup' || return 1

    if [ -z "${REAL_USER}" ] || [ "${REAL_USER}" = "root" ]; then
        log "WARN" "Installing Rust for root user. Recommended to run as a normal user with sudo."
        export HOME=/root

        if ! run_installer_cmd sh "${rustup_installer}" -y --default-toolchain stable --component rust-analyzer; then
            local exit_code=$?
            rm -f "${rustup_installer}"
            return "${exit_code}"
        fi

        if [ ! -f "${HOME}/.cargo/env" ]; then
            log "ERROR" "rustup finished but ${HOME}/.cargo/env was not found"
            rm -f "${rustup_installer}"
            return 1
        fi

        export PATH="${HOME}/.cargo/bin:${PATH}"

        install_root_cargo_crate_if_missing tree-sitter tree-sitter-cli
        install_root_cargo_crate_if_missing eza eza
        install_root_cargo_crate_if_missing zoxide zoxide
    else
        if ! run_installer_cmd sudo -u "${REAL_USER}" sh "${rustup_installer}" -y --default-toolchain stable --component rust-analyzer; then
            local exit_code=$?
            rm -f "${rustup_installer}"
            return "${exit_code}"
        fi

        install_user_cargo_crate_if_missing tree-sitter tree-sitter-cli
        install_user_cargo_crate_if_missing eza eza
        install_user_cargo_crate_if_missing zoxide zoxide
    fi

    rm -f "${rustup_installer}"
}

step_install_flatpak_and_obsidian() {
    if ! command -v flatpak >/dev/null 2>&1; then
        log "INFO" "Flatpak not found. Installing..."
        run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" flatpak
    else
        log "INFO" "Flatpak already installed."
    fi

    log "INFO" "Ensuring Flathub remote is configured (system scope)..."
    run_package_cmd flatpak remote-add --system --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    if ! flatpak list --system | grep -q "md.obsidian.Obsidian"; then
        log "INFO" "Installing Obsidian..."
        run_package_cmd flatpak install --system --noninteractive -y flathub md.obsidian.Obsidian
    else
        log "INFO" "Obsidian already installed."
    fi
}

step_install_snap() {
    if ! command -v snap >/dev/null 2>&1; then
        log "INFO" "Snap not found. Installing..."
        run_dnf_cmd install "${DNF_INSTALL_FLAGS[@]}" snapd

        if ! command -v systemctl >/dev/null 2>&1; then
            log "WARN" "systemctl is unavailable; skipping snapd.socket enable/start in this non-systemd environment."
            return 0
        fi

        if [ ! -d /run/systemd/system ]; then
            log "WARN" "/run/systemd/system not found; skipping snapd.socket enable/start in this non-systemd environment."
            return 0
        fi

        if [ "$(ps -p 1 -o comm= 2>/dev/null | tr -d '[:space:]')" != "systemd" ]; then
            log "WARN" "PID 1 is not systemd; skipping snapd.socket enable/start in this environment."
            return 0
        fi

        run_package_cmd systemctl enable --now snapd.socket
        ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
    else
        log "INFO" "Snap already installed."
    fi
}

step_configure_shell() {
    if [ -n "${REAL_USER}" ] && [ "${REAL_USER}" != "root" ]; then
        append_bashrc_block_if_missing "${USER_HOME}/.bashrc" "dev-alias" \
            "# Development tool aliases
alias ls=\"eza\"
alias ll=\"eza -la\"
alias lt=\"eza --tree\"
alias cat=\"bat\"
alias vim=\"nvim\"
eval \"\$(zoxide init bash)\"

# Add local bin to PATH
export PATH=\"\$HOME/.local/bin:\$PATH\""

        log "INFO" "Added aliases to ${USER_HOME}/.bashrc"
        log "INFO" "Please run: source ~/.bashrc"
    else
        log "INFO" "Skipping shell configuration for root user."
        log "INFO" "Please manually add aliases to your user's ~/.bashrc"
    fi
}

echo "=== Fedora Development Environment Installation ==="
echo "This script will install development tools and utilities."
echo

require_root
initialize_user_context

run_step "[1/14] Updating package lists" critical step_update_package_lists
run_step "[2/14] Installing Build Tools" critical step_install_build_tools
run_step "[3/14] Installing Terminal Utilities" critical step_install_terminal_utilities
run_step "[4/14] Installing Editors" critical step_install_editors
run_step "[5/14] Installing Git Tools" critical step_install_git_tools
run_step "[6/14] Installing GitHub CLI" critical step_install_github_cli
run_step "[7/14] Installing Lazygit" critical step_install_lazygit
run_step "[8/14] Installing Python, pipx, and Astral uv" critical step_install_python_tools
run_step "[9/14] Installing Node.js" critical step_install_node
run_step "[10/14] Installing Bun" critical step_install_bun
run_step "[11/14] Installing Rust and Cargo tools" critical step_install_rust_tools
run_step "[12/14] Installing Flatpak and Obsidian" optional step_install_flatpak_and_obsidian
run_step "[13/14] Installing Snap" optional step_install_snap
run_step "[14/14] Configuring Shell" critical step_configure_shell

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
