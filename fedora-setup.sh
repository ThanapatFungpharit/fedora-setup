#!/usr/bin/env bash
# Fedora workstation setup: repos, codecs, NVIDIA, dev tools, shell and configs.
# Run as your normal user; sudo is used where needed. Safe to re-run.
set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '%s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

FAILED=()
TUI_STTY_STATE=

# try LABEL CMD...: run a step; on failure record it and keep going.
try() {
  local label=$1; shift
  "$@" || { warn "$label failed"; FAILED+=("$label"); }
}

# step TITLE LABEL CMD...: log a heading, then run CMD via try.
step() {
  log "$1"; shift
  try "$@"
}

pkg_installed() { rpm -q "$@" >/dev/null 2>&1; }

# curl with retries and timeouts, so a flaky network doesn't sink a step.
fetch() { curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 15 "$@"; }

# Required packages: one dnf transaction for whatever is missing; if that
# fails, retry package by package and record each one that still fails.
dnf_install() {
  local p missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  sudo dnf install -y "${missing[@]}" && return 0
  for p in "${missing[@]}"; do
    pkg_installed "$p" || sudo dnf install -y "$p" \
      || { warn "dnf: could not install $p"; FAILED+=("dnf:$p"); }
  done
  return 0
}

# Install if missing; return non-zero on failure so callers can fall back.
dnf_try() { pkg_installed "$1" || sudo dnf install -y "$1"; }

# Optional package: failure is only a warning.
dnf_opt() { dnf_try "$1" || warn "optional package $1 unavailable; skipping"; }

# Scratch space for downloads, removed on exit.
TMP_ROOT=$(mktemp -d)
KEEPALIVE_PID=
cleanup() {
  if [[ -n ${TUI_STTY_STATE:-} ]]; then
    stty "$TUI_STTY_STATE" 2>/dev/null || true
    TUI_STTY_STATE=
    printf '\033[?25h' 2>/dev/null || true
  fi
  rm -rf "$TMP_ROOT"
  [[ -n $KEEPALIVE_PID ]] && kill "$KEEPALIVE_PID" 2>/dev/null
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

scratch_dir() { mktemp -d -p "$TMP_ROOT"; }

# The login name; $USER can be unset (containers, some su/sudo setups).
USER_NAME=$(id -un)

# Install a single binary named BIN from the latest GitHub release of REPO
# whose asset name matches the regex PATTERN (a .tar.gz). Uses GITHUB_TOKEN or
# GH_TOKEN if set, to avoid the 60 requests/hour anonymous API limit.
install_tarball_bin() {
  local repo=$1 pattern=$2 name=$3 url tmp bin token=${GITHUB_TOKEN:-${GH_TOKEN:-}}
  local auth=()
  dnf_install jq tar
  [[ -z $token ]] || auth=(-H "Authorization: Bearer $token")
  url=$(fetch "${auth[@]}" "https://api.github.com/repos/$repo/releases/latest" \
        | jq -r --arg re "$pattern" \
            '[.assets[] | select(.name | test($re)) | .browser_download_url][0] // empty') || return 1
  [[ -n $url ]] || return 1
  tmp=$(scratch_dir)
  fetch "$url" -o "$tmp/pkg.tar.gz" || return 1
  tar -xzf "$tmp/pkg.tar.gz" -C "$tmp" || return 1
  bin=$(find "$tmp" -type f -name "$name" | head -n1)
  [[ -n $bin ]] || return 1
  install -Dm755 "$bin" "$HOME/.local/bin/$name"
}

# Download a remote install script to a file first (so a dropped connection
# can't run a truncated script), then run it:
#   curl_sh URL [VAR=VALUE...] SHELL [ARGS...]
curl_sh() {
  local url=$1 file
  shift
  local envs=()
  while [[ ${1:-} == [A-Za-z_]*=* ]]; do envs+=("$1"); shift; done
  [[ $# -gt 0 ]] || return 1
  file="$(scratch_dir)/install.sh"
  fetch "$url" -o "$file" || return 1
  env "${envs[@]}" "$1" "$file" "${@:2}"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# Checks that need no sudo; run before the menu so a bad environment fails fast.
check_environment() {
  [[ $EUID -ne 0 ]] || die "Run this as your normal user (it uses sudo where needed), not as root."

  # shellcheck source=/dev/null
  . /etc/os-release
  [[ ${ID:-} == fedora ]] || die "This script is for Fedora only."
  [[ ! -e /run/ostree-booted ]] \
    || die "Image-based Fedora (Silverblue/Kinoite/Atomic) detected; this script needs a regular dnf-based Fedora."

  case "$(uname -m)" in
    x86_64)  RUST_ARCH=x86_64;  TB_KEY=linux ;;
    aarch64) RUST_ARCH=aarch64; TB_KEY=linuxARM64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
  esac
}

preflight() {
  # Prompt once, then keep the sudo timestamp fresh until we exit.
  sudo -v
  # Detached from stdout/stderr so a lingering `sleep` can't keep a pipe
  # (e.g. `| tee setup.log`) open after the script ends.
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true; sleep 50; done ) >/dev/null 2>&1 &
  KEEPALIVE_PID=$!

  mkdir -p "$HOME/.local/bin" "$HOME/.local/opt" "$HOME/.config"
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
}

# ---------------------------------------------------------------------------
# System: DNF, repos, Flatpak, multimedia
# ---------------------------------------------------------------------------

configure_dnf() {
  grep -q '^max_parallel_downloads' /etc/dnf/dnf.conf \
    || sudo sed -i '/^\[main\]/a max_parallel_downloads=10' /etc/dnf/dnf.conf
}

enable_repos() {
  local mirror="https://download1.rpmfusion.org" fedora_ver
  fedora_ver=$(rpm -E %fedora)
  if ! pkg_installed rpmfusion-free-release rpmfusion-nonfree-release; then
    sudo dnf install -y \
      "$mirror/free/fedora/rpmfusion-free-release-$fedora_ver.noarch.rpm" \
      "$mirror/nonfree/fedora/rpmfusion-nonfree-release-$fedora_ver.noarch.rpm" || return 1
  fi

  sudo dnf install -y dnf5-plugins 2>/dev/null || sudo dnf install -y dnf-plugins-core || return 1

  sudo dnf install -y rpmfusion-free-release-tainted rpmfusion-nonfree-release-tainted \
    || warn "RPM Fusion tainted repos unavailable; skipping"
  sudo dnf install -y rpmfusion-free-appstream-data rpmfusion-nonfree-appstream-data \
    || warn "RPM Fusion appstream data unavailable; skipping"

  # dnf5 syntax first, then dnf4.
  sudo dnf config-manager setopt fedora-cisco-openh264.enabled=1 2>/dev/null \
    || sudo dnf config-manager --set-enabled fedora-cisco-openh264 2>/dev/null \
    || warn "Could not enable fedora-cisco-openh264"
  sudo dnf install -y openh264 gstreamer1-plugin-openh264 mozilla-openh264 \
    || warn "OpenH264 packages unavailable; skipping"
}

configure_flatpak() {
  have flatpak || sudo dnf install -y flatpak || return 1
  sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo || return 1
  sudo flatpak remote-modify --no-filter --enable flathub \
    || warn "Could not unfilter/enable the flathub remote"
  sudo flatpak remote-add --if-not-exists fedora oci+https://registry.fedoraproject.org \
    || warn "Could not add the fedora Flatpak remote"
}

install_multimedia() {
  # Runs under `try`, where `set -e` is off, so chain failures explicitly.
  if pkg_installed ffmpeg-free; then
    sudo dnf swap ffmpeg-free ffmpeg --allowerasing -y || return 1
  elif ! pkg_installed ffmpeg; then
    sudo dnf install -y ffmpeg --allowerasing || return 1
  fi
  sudo dnf group install multimedia --with-optional -y || return 1
  sudo dnf group install sound-and-video -y
}

# ---------------------------------------------------------------------------
# NVIDIA
# ---------------------------------------------------------------------------

NEEDS_MOK=0
NV_REBOOT=0
HYBRID=0
MOK_CERT=/etc/pki/akmods/certs/public_key.der

# Sets HAS_NVIDIA and HYBRID from the PCI display controllers.
detect_gpus() {
  local d class vendor other=0
  HAS_NVIDIA=0
  for d in /sys/bus/pci/devices/*; do
    [[ -r $d/class ]] || continue
    class=$(<"$d/class"); vendor=$(<"$d/vendor")
    [[ $class == 0x03* ]] || continue
    case $vendor in
      0x10de)        HAS_NVIDIA=1 ;;
      0x8086|0x1002) other=1 ;;
    esac
  done
  ((HAS_NVIDIA && other)) && HYBRID=1
  return 0
}

# Map an NVIDIA chip codename to the RPM Fusion driver branch.
nvidia_branch() {
  case $1 in
    GK*)                       echo 470xx ;;
    GF*)                       echo 390xx ;;
    GM*|GP*|GV*)               echo 580xx ;;
    G[0-9]*|GT[0-9]*|NV*|MCP*) echo unsupported ;;
    *)                         echo current ;;
  esac
}

prepare_secure_boot() {
  local enrolled
  grep -qi 'SecureBoot enabled' <<<"$(mokutil --sb-state 2>&1 || true)" || return 0
  sudo test -f "$MOK_CERT" || sudo kmodgenca -a || return 1
  enrolled=$(sudo mokutil --test-key "$MOK_CERT" 2>&1 || true)
  grep -qi 'already enrolled' <<<"$enrolled" || NEEDS_MOK=1
}

setup_hybrid_graphics() {
  local sfx=$1
  dnf_opt "xorg-x11-drv-nvidia$sfx-power"
  sudo systemctl enable nvidia-suspend.service nvidia-resume.service nvidia-hibernate.service \
    >/dev/null 2>&1 || true
  dnf_opt switcheroo-control
  sudo systemctl enable --now switcheroo-control.service >/dev/null 2>&1 || true
  cat > "$HOME/.local/bin/prime-run" <<'EOF'
#!/bin/sh
# Run a program on the NVIDIA GPU (PRIME render offload).
export __NV_PRIME_RENDER_OFFLOAD=1 __GLX_VENDOR_LIBRARY_NAME=nvidia __VK_LAYER_NV_optimus=NVIDIA_only
exec "$@"
EOF
  chmod +x "$HOME/.local/bin/prime-run"
}

nvidia_module_built() { modinfo -F version -k "$1" nvidia >/dev/null 2>&1; }

# Wait for akmods to build the module for KERNEL, forcing a build if needed.
wait_for_nvidia_module() {
  local kernel=$1 i
  echo "Waiting for the NVIDIA kernel module to build for $kernel (can take several minutes)..."
  for ((i = 0; i < 60; i++)); do
    nvidia_module_built "$kernel" && return 0
    ((i >= 3)) && ! pgrep -f akmods >/dev/null 2>&1 && break
    sleep 10
  done
  nvidia_module_built "$kernel" && return 0
  warn "Module not built yet; forcing a build..."
  sudo akmods --force --kernels "$kernel" || true
  nvidia_module_built "$kernel" && return 0
  warn "NVIDIA kernel module did not build. Check /var/cache/akmods/ for *.failed.log, then re-run this script."
  return 1
}

setup_nvidia() {
  detect_gpus
  if ((!HAS_NVIDIA)); then
    echo "No NVIDIA GPU detected; skipping NVIDIA driver install."
    return 0
  fi

  dnf_install pciutils
  local line chip branch sfx newest
  line=$(lspci -d 10de: -nn 2>/dev/null | grep -E '\[03(00|02|80)\]' | head -n1 || true)
  chip=$(sed -nE 's/.*NVIDIA Corporation ([A-Za-z0-9]+).*/\1/p' <<<"$line")
  branch=$(nvidia_branch "$chip")
  echo "NVIDIA GPU: ${line:-unknown}"
  echo "  -> driver branch: $branch, hybrid laptop: $( ((HYBRID)) && echo yes || echo no)"

  if [[ $branch == unsupported ]]; then
    warn "This NVIDIA GPU is too old for any packaged driver; staying on the open-source nouveau driver."
    return 0
  fi
  [[ $branch == current ]] && sfx="" || sfx="-$branch"

  sudo dnf install -y kmodtool akmods mokutil openssl || return 1
  prepare_secure_boot || return 1

  # Build against the newest installed kernel, not necessarily the running one.
  newest=$(rpm -q kernel-core --qf '%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort -V | tail -n1)
  sudo dnf install -y "kernel-devel-$newest" || sudo dnf install -y kernel-devel || true

  if ! sudo dnf install -y "akmod-nvidia$sfx" "xorg-x11-drv-nvidia$sfx"; then
    warn "Could not install the NVIDIA $branch driver from RPM Fusion for Fedora $VERSION_ID."
    return 1
  fi
  # Keep the driver from being autoremoved.
  sudo dnf mark user "akmod-nvidia$sfx" >/dev/null 2>&1 \
    || sudo dnf mark install "akmod-nvidia$sfx" >/dev/null 2>&1 || true
  dnf_opt "xorg-x11-drv-nvidia$sfx-cuda"
  dnf_opt libva-nvidia-driver
  dnf_opt nvidia-settings

  ((HYBRID)) && setup_hybrid_graphics "$sfx"

  wait_for_nvidia_module "$newest" || return 1
  sudo dracut --force --kver "$newest" || warn "dracut failed; run: sudo dracut --force"
  NV_REBOOT=1
}

enroll_mok() {
  ((NEEDS_MOK)) || return 0
  if [[ ! -t 0 ]]; then
    warn "Secure Boot is on but there's no terminal. Run: sudo mokutil --import $MOK_CERT"
    return 0
  fi
  echo
  echo "Secure Boot is enabled. Choose a one-time password now; on the next boot pick"
  echo "'Enroll MOK' -> Continue -> Yes and enter that password so the NVIDIA driver can load."
  sudo mokutil --import "$MOK_CERT"
}

# ---------------------------------------------------------------------------
# Desktop
# ---------------------------------------------------------------------------

detect_desktop() {
  local d="${XDG_CURRENT_DESKTOP:-} ${DESKTOP_SESSION:-}"
  case ${d,,} in
    *gnome*)        echo gnome; return ;;
    *kde*|*plasma*) echo kde;   return ;;
  esac
  if   pkg_installed plasma-desktop; then echo kde
  elif pkg_installed gnome-shell;    then echo gnome
  else echo other
  fi
}

PAPIRUS_FOLDER_COLOR="${PAPIRUS_FOLDER_COLOR:-breeze}"
PAPIRUS_RAW=https://raw.githubusercontent.com/PapirusDevelopmentTeam

setup_papirus() {
  local icons="$HOME/.local/share/icons" scheme theme t marker="$HOME/.config/fedora-setup/papirus-configured"

  if [[ ! -d $icons/Papirus ]]; then
    mkdir -p "$icons"
    curl_sh "$PAPIRUS_RAW/papirus-icon-theme/master/install.sh" DESTDIR="$icons" sh || return 1
  fi
  if ! have papirus-folders; then
    curl_sh "$PAPIRUS_RAW/papirus-folders/master/install.sh" PREFIX="$HOME/.local" sh || return 1
  fi
  dnf_opt gtk-update-icon-cache
  # Do not reset a user's folder color or icon theme on every re-run.
  if [[ ! -f $marker ]]; then
    for t in Papirus Papirus-Dark Papirus-Light; do
      papirus-folders -C "$PAPIRUS_FOLDER_COLOR" --theme "$t" || warn "papirus-folders failed for $t"
    done

    # Match the icon variant to the current Plasma color scheme.
    scheme=$(kreadconfig6 --file kdeglobals --group General --key ColorScheme 2>/dev/null || true)
    case ${scheme,,} in
      *dark*)  theme=Papirus-Dark ;;
      *light*) theme=Papirus-Light ;;
      *)       theme=Papirus ;;
    esac
    /usr/libexec/plasma-changeicons "$theme" >/dev/null 2>&1 \
      || kwriteconfig6 --file kdeglobals --group Icons --key Theme "$theme" 2>/dev/null \
      || warn "Could not apply $theme automatically; pick it in System Settings > Colors & Themes > Icons"
    mkdir -p "$(dirname "$marker")"
    : > "$marker"
  fi
  echo "Papirus installed; existing icon and folder preferences were preserved."
}

setup_desktop() {
  local desktop
  desktop=$(detect_desktop)
  echo "Desktop environment: $desktop"
  case $desktop in
    gnome) dnf_install gnome-tweaks ;;
    kde)   setup_papirus ;;
    *)     echo "No GNOME/KDE desktop detected; skipping desktop-specific packages." ;;
  esac
}

# ---------------------------------------------------------------------------
# Applications and tools
# ---------------------------------------------------------------------------

# Everyday CLI tools. Components that need a package (zsh, git, jq, gh, ...)
# install it themselves, so this group is optional.
CORE_PACKAGES=(
  curl wget tar xz unzip jq fontconfig util-linux-user fuse fuse-libs
  git zsh tmux ripgrep fzf btop bat fd-find eza zoxide git-delta
)

install_core() { dnf_install "${CORE_PACKAGES[@]}"; }

do_upgrade() {
  sudo dnf upgrade --refresh -y
}

update_flatpak() {
  have flatpak || return 0
  sudo flatpak update -y
}

# Nice-to-have CLI tools; a missing one is only a warning.
EXTRA_PACKAGES=(
  # System info and monitoring
  fastfetch htop inxi lm_sensors smartmontools nvme-cli lsof strace duf ncdu procs
  # Networking
  nmap bind-utils traceroute mtr whois iperf3 httpie wireguard-tools
  # Files and archives
  tree rsync 7zip unrar zip plocate entr
  # Editors and docs
  vim-enhanced neovim tldr
  # Development
  gcc gcc-c++ make cmake git-lfs yq hyperfine tokei ShellCheck
)

# One dnf transaction that skips unavailable packages; per-package fallback otherwise.
install_extra_packages() {
  local p missing=()
  for p in "${EXTRA_PACKAGES[@]}"; do pkg_installed "$p" || missing+=("$p"); done
  ((${#missing[@]})) || return 0
  sudo dnf install -y --skip-unavailable "${missing[@]}" && return 0
  for p in "${missing[@]}"; do dnf_opt "$p"; done
}

install_starship() {
  have starship || dnf_try starship \
    || curl_sh https://starship.rs/install.sh sh -y -b "$HOME/.local/bin"
}

install_claudecode() {
  have claude || curl_sh https://claude.ai/install.sh bash
}

install_worktrunk() {
  have wt || curl_sh https://github.com/max-sixty/worktrunk/releases/latest/download/worktrunk-installer.sh sh \
    || return 1
  have wt || return 1
  # Shell integration edits your rc files and is idempotent; the Claude plugin
  # needs the claude CLI, so only try it when that is installed.
  wt config shell install || warn "wt shell integration failed; run: wt config shell install"
  if have claude; then
    wt config plugins claude install || warn "wt Claude plugin failed; run: wt config plugins claude install"
  fi
}

install_dust() {
  have dust || dnf_try dust || dnf_try du-dust \
    || install_tarball_bin bootandy/dust "${RUST_ARCH}-unknown-linux-gnu\\.tar\\.gz\$" dust
}

install_docker() {
  # `podman-docker` also provides a docker command, but not dockerd.
  if ! pkg_installed docker-ce && ! pkg_installed moby-engine; then
    local repo_file
    repo_file="$(scratch_dir)/docker-ce.repo"
    fetch https://download.docker.com/linux/fedora/docker-ce.repo -o "$repo_file" || return 1
    sudo install -m 0644 "$repo_file" /etc/yum.repos.d/docker-ce.repo || return 1
    if ! sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
      warn "Docker's repo has no packages for Fedora $VERSION_ID yet; using Fedora's moby-engine instead"
      sudo rm -f /etc/yum.repos.d/docker-ce.repo
      sudo dnf install -y moby-engine docker-compose || return 1
    fi
  fi
  sudo systemctl enable --now docker || return 1
  sudo usermod -aG docker "$USER_NAME"
}

# Prefer the distro package, fall back to the COPR.
install_lazygit() {
  have lazygit && return 0
  dnf_try lazygit && return 0
  copr_install atim/lazygit lazygit
}

# copr_install COPR PKG: install PKG from a COPR repo unless already present.
copr_install() {
  have "$2" && return 0
  sudo dnf copr enable -y "$1" && sudo dnf install -y "$2"
}

install_wezterm() {
  copr_install wezfurlong/wezterm-nightly wezterm && return 0
  warn "WezTerm COPR failed; falling back to Flatpak"
  flatpak_app org.wezfurlong.wezterm
}

# flatpak_app REF: install a system-wide Flathub app unless already present.
flatpak_app() {
  flatpak info --system "$1" >/dev/null 2>&1 && return 0
  sudo flatpak install -y --noninteractive --system flathub "$1"
}

firewalld_running() { have firewall-cmd && sudo firewall-cmd --state >/dev/null 2>&1; }

install_zen() { flatpak_app app.zen_browser.zen; }

install_ente_auth() { flatpak_app io.ente.auth; }

# LocalSend discovers peers on 53317 (TCP and UDP), so open it with the app.
install_localsend() {
  flatpak_app org.localsend.localsend_app || return 1
  if firewalld_running; then
    local changed=0
    if ! sudo firewall-cmd --query-port=53317/tcp >/dev/null 2>&1; then
      sudo firewall-cmd --permanent --add-port=53317/tcp || return 1
      changed=1
    fi
    if ! sudo firewall-cmd --query-port=53317/udp >/dev/null 2>&1; then
      sudo firewall-cmd --permanent --add-port=53317/udp || return 1
      changed=1
    fi
    ((changed == 0)) || sudo firewall-cmd --reload || return 1
  fi
}

install_unity_hub() {
  sudo tee /etc/yum.repos.d/unityhub.repo >/dev/null <<'EOF'
[unityhub]
name=Unity Hub
baseurl=https://hub.unity3d.com/linux/repos/rpm/stable
enabled=1
gpgcheck=1
gpgkey=https://hub.unity3d.com/linux/repos/rpm/stable/repodata/repomd.xml.key
repo_gpgcheck=1
EOF
  sudo dnf install -y unityhub
}

install_uv() { have uv || curl_sh https://astral.sh/uv/install.sh UV_NO_MODIFY_PATH=1 sh; }

install_bun() {
  have bun && return 0
  dnf_install unzip   # the Bun installer needs it
  curl_sh https://bun.sh/install bash
}

install_zed() { have zed || curl_sh https://zed.dev/install.sh sh; }

install_lazydocker() {
  have lazydocker || curl_sh \
    https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update_linux.sh \
    DIR="$HOME/.local/bin" bash
}

install_toolbox() {
  local dest="$HOME/.local/opt/jetbrains-toolbox" url tmp bin
  dnf_install jq tar fuse fuse-libs
  # Done if Toolbox has already installed itself or our unpacked copy is usable
  # (an empty leftover $dest from a failed run must not count as installed).
  [[ -x $HOME/.local/share/JetBrains/Toolbox/bin/jetbrains-toolbox || -x $HOME/.local/bin/jetbrains-toolbox ]] \
    && return 0
  rm -rf "$dest"
  url=$(fetch 'https://data.services.jetbrains.com/products/releases?code=TBA&latest=true&type=release' \
        | jq -r --arg k "$TB_KEY" '.TBA[0].downloads[$k].link // empty') || return 1
  [[ -n $url ]] || return 1
  tmp=$(scratch_dir)
  fetch "$url" -o "$tmp/tb.tar.gz" || return 1
  mkdir -p "$dest"
  tar -xzf "$tmp/tb.tar.gz" -C "$dest" --strip-components=1 || { rm -rf "$dest"; return 1; }
  bin=$(find "$dest" -type f -name jetbrains-toolbox | head -n1)
  [[ -n $bin ]] || { rm -rf "$dest"; return 1; }
  chmod +x "$bin"
  ln -sf "$bin" "$HOME/.local/bin/jetbrains-toolbox"
  mkdir -p "$HOME/.local/share/applications"
  cat > "$HOME/.local/share/applications/jetbrains-toolbox.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=JetBrains Toolbox
Exec=$bin
Terminal=false
Categories=Development;IDE;
EOF
}

install_nerd_font() {
  local tmp dir="$HOME/.local/share/fonts/JetBrainsMonoNerd"
  dnf_install fontconfig xz tar
  [[ $(fc-list 2>/dev/null || true) == *"JetBrainsMono Nerd"* ]] && return 0
  tmp=$(scratch_dir)
  fetch https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz \
    -o "$tmp/font.tar.xz" || return 1
  mkdir -p "$dir"
  tar -xf "$tmp/font.tar.xz" -C "$dir" || return 1
  fc-cache -f "$dir"
}

# ---------------------------------------------------------------------------
# Shell and dotfiles
# ---------------------------------------------------------------------------

ZSHRC_BEGIN='# >>> fedora-setup >>>'
ZSHRC_END='# <<< fedora-setup <<<'

clone_if_missing() { [[ -d $2/.git ]] || { rm -rf "$2"; git clone --depth=1 "$1" "$2"; }; }

# Plugins we want enabled. zsh-syntax-highlighting must stay last.
OMZ_PLUGINS=(git sudo docker docker-compose fzf zsh-autosuggestions)

# Merge OMZ_PLUGINS into the plugins=(...) line instead of replacing it, so
# plugins you added yourself survive a re-run.
ensure_omz_plugins() {
  local rc=$1 cur p new=() declaration
  declaration=$(grep -nE '^plugins=\(' "$rc" | head -n1 || true)
  if [[ -n $declaration ]]; then
    # Only rewrite a one-line array. Never shadow a user's multiline array.
    if ! grep -qE '^plugins=\([^)]*\)[[:space:]]*$' "$rc"; then
      warn "Found a multiline or nonstandard plugins=(...) declaration in $rc; leaving it untouched."
      return 0
    fi
    cur=$(sed -nE 's/^plugins=\(([^)]*)\)[[:space:]]*$/\1/p' "$rc" | head -n1)
    for p in $cur; do
      [[ $p == zsh-syntax-highlighting ]] || new+=("$p")
    done
    for p in "${OMZ_PLUGINS[@]}"; do
      [[ " ${new[*]-} " == *" $p "* ]] || new+=("$p")
    done
    new+=(zsh-syntax-highlighting)
    sed -i -E "s|^plugins=\([^)]*\)[[:space:]]*$|plugins=(${new[*]})|" "$rc"
  else
    # Add a default only when no plugins declaration exists at all.
    sed -i '0,/^source .*oh-my-zsh\.sh/s//plugins=(git)\n&/' "$rc"
  fi
}

setup_shell() {
  local rc="$HOME/.zshrc" custom omz_installer
  dnf_install zsh git
  have zsh || return 1
  # Judge "installed" by the entry point, not just the directory: an earlier
  # failed run can leave ~/.oh-my-zsh behind without Oh My Zsh in it.
  if [[ ! -f $HOME/.oh-my-zsh/oh-my-zsh.sh ]]; then
    omz_installer="$(scratch_dir)/omz-install.sh"
    fetch https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh -o "$omz_installer" || return 1
    if [[ -d $HOME/.oh-my-zsh ]]; then
      warn "Found a broken ~/.oh-my-zsh; moving it to ~/.oh-my-zsh.broken"
      rm -rf "$HOME/.oh-my-zsh.broken"
      mv "$HOME/.oh-my-zsh" "$HOME/.oh-my-zsh.broken"
    fi
    RUNZSH=no CHSH=no KEEP_ZSHRC=yes sh "$omz_installer" --unattended || return 1
    [[ -f $HOME/.oh-my-zsh/oh-my-zsh.sh ]] || return 1
  fi
  custom="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
  clone_if_missing https://github.com/zsh-users/zsh-autosuggestions "$custom/plugins/zsh-autosuggestions" || return 1
  clone_if_missing https://github.com/zsh-users/zsh-syntax-highlighting "$custom/plugins/zsh-syntax-highlighting" || return 1

  [[ -f $rc ]] || touch "$rc"
  [[ -f $rc.pre-setup ]] || cp "$rc" "$rc.pre-setup"
  # Make sure the file ends with a newline before we append anything.
  [[ -z $(tail -c1 "$rc") ]] || echo >> "$rc"

  # An .zshrc that predates Oh My Zsh (KEEP_ZSHRC=yes keeps it as-is, e.g. one
  # created by `wt config shell install`) never loads it; wire it up.
  if ! grep -qE '^[[:space:]]*(source|\.)[[:space:]].*oh-my-zsh\.sh' "$rc"; then
    cat >> "$rc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=""
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
EOF
  fi

  # Starship draws the prompt, so disable the Oh My Zsh theme.
  sed -i 's/^ZSH_THEME=.*/ZSH_THEME=""/' "$rc"
  ensure_omz_plugins "$rc"

  # Replace our managed block so re-runs don't duplicate it.
  sed -i "\\|^$ZSHRC_BEGIN\$|,\\|^$ZSHRC_END\$|d" "$rc"
  {
    echo "$ZSHRC_BEGIN"
    cat <<'EOF'
typeset -U path PATH
path=("$HOME/.local/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin" $path)
export BUN_INSTALL="$HOME/.bun"

# fzf (each setting is only applied if the tool it relies on is installed,
# so a failed install can't break the shell)
export FZF_DEFAULT_OPTS='--height 40% --layout=reverse --border'
if (( $+commands[fd] )); then
  export FZF_DEFAULT_COMMAND='fd --type f --hidden --follow --exclude .git'
  export FZF_CTRL_T_COMMAND="$FZF_DEFAULT_COMMAND"
  export FZF_ALT_C_COMMAND='fd --type d --hidden --follow --exclude .git'
fi
(( $+commands[bat] )) && export FZF_CTRL_T_OPTS="--preview 'bat --color=always --line-range :200 {}'"
(( $+commands[eza] )) && export FZF_ALT_C_OPTS="--preview 'eza --tree --level=2 --icons auto --color=always {}'"

# Colored man pages
(( $+commands[bat] )) && export MANPAGER="sh -c 'col -bx | bat -l man -p'"

# Modern replacements. find/du are deliberately not aliased: fd and dust take
# different arguments, so aliasing them breaks pasted commands and scripts.
if (( $+commands[eza] )); then
  alias ls='eza -F -s type --git --icons auto'
  alias la='eza -AF -s type --git --icons auto'
  alias ll='eza -lbHAF -s type --git --icons auto'
  alias lt='eza --tree --level=2 -F --git --icons auto'
fi
(( $+commands[bat] ))        && alias cat='bat --paging=never'
(( $+commands[btop] ))       && alias top='btop'
(( $+commands[lazygit] ))    && alias lg='lazygit'
(( $+commands[lazydocker] )) && alias lzd='lazydocker'
alias ..='cd ..'
alias ...='cd ../..'
alias c='clear'

alias zshconfig='nano ~/.zshrc'
alias ohmyzsh="nano ~/.oh-my-zsh"

# Completions are generated once and sourced from cache on later shell starts.
if (( $+commands[uv] )); then
  uv_completion="$HOME/.cache/fedora-setup/uv.zsh"
  if [[ ! -s $uv_completion ]]; then
    mkdir -p "${uv_completion:h}"
    uv generate-shell-completion zsh >| "$uv_completion" 2>/dev/null
  fi
  [[ -s $uv_completion ]] && source "$uv_completion"
fi
if (( $+commands[uvx] )); then
  uvx_completion="$HOME/.cache/fedora-setup/uvx.zsh"
  if [[ ! -s $uvx_completion ]]; then
    mkdir -p "${uvx_completion:h}"
    uvx --generate-shell-completion zsh >| "$uvx_completion" 2>/dev/null
  fi
  [[ -s $uvx_completion ]] && source "$uvx_completion"
fi

# Prompt and navigation (keep last)
(( $+commands[zoxide]   )) && eval "$(zoxide init zsh)"
(( $+commands[starship] )) && eval "$(starship init zsh)"
EOF
    echo "$ZSHRC_END"
  } >> "$rc"

  if [[ "$(getent passwd "$USER_NAME" | cut -d: -f7)" != */zsh ]]; then
    sudo usermod --shell "$(command -v zsh)" "$USER_NAME"
  fi
}

# write_if_missing PATH: write stdin to PATH unless it already exists.
write_if_missing() {
  [[ -e $1 ]] && { cat >/dev/null; return 0; }
  mkdir -p "$(dirname "$1")"
  cat > "$1"
}

git_config_if_missing() {
  local key=$1 value=$2
  [[ -n $(git config --global --get "$key" 2>/dev/null || true) ]] || git config --global "$key" "$value"
}

setup_configs() {
  have git || dnf_install git
  git_config_if_missing init.defaultBranch main
  # Only point git at delta if it exists; otherwise every `git log`/`git diff` fails.
  if have delta; then
    git_config_if_missing core.pager delta
    git_config_if_missing interactive.diffFilter 'delta --color-only'
    git_config_if_missing delta.navigate true
    git_config_if_missing delta.line-numbers true
  else
    warn "delta not installed; leaving git's pager settings alone"
  fi
  git_config_if_missing merge.conflictstyle zdiff3

  write_if_missing "$HOME/.tmux.conf" <<'EOF'
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g history-limit 50000
set -g escape-time 10
set -g default-terminal "tmux-256color"
set -ag terminal-overrides ",*:RGB"
bind r source-file ~/.tmux.conf \; display "Reloaded"
EOF

  # Only write a WezTerm config if WezTerm is installed (RPM or Flatpak).
  if [[ ! -f $HOME/.wezterm.lua ]] \
      && { have wezterm || flatpak info --system org.wezfurlong.wezterm >/dev/null 2>&1; }; then
    write_if_missing "$HOME/.config/wezterm/wezterm.lua" <<'EOF'
local wezterm = require 'wezterm'
local config = wezterm.config_builder()

config.font = wezterm.font 'JetBrainsMono Nerd Font'
config.font_size = 12.0
config.color_scheme = 'Catppuccin Mocha'
config.hide_tab_bar_if_only_one_tab = true
config.scrollback_lines = 20000

return config
EOF
  fi
}

STARSHIP_MARKER='# Managed by fedora-setup.sh; delete this line to keep your own edits.'

# Two-line Catppuccin Mocha powerline prompt (matches the WezTerm scheme):
#   ╭─ os user  dir  git  languages  containers ......... status  took  jobs  ram  time
#   ╰─❯
# Glyphs are \u escapes so the file survives editors without Nerd Fonts.
starship_config() {
  echo "$STARSHIP_MARKER"
  cat <<'EOF'
"$schema" = 'https://starship.rs/config-schema.json'

palette = "catppuccin_mocha"
add_newline = true
continuation_prompt = "[╰─∙ ](fg:overlay1)"

format = """
[╭─](fg:overlay1)\
[](fg:red)\
$os$username$hostname\
[ ](bg:red)\
[](fg:red bg:peach)\
$directory\
[](fg:peach bg:yellow)\
$git_branch$git_state$git_status$git_metrics\
[](fg:yellow bg:green)\
$c$cpp$rust$golang$nodejs$bun$deno$python$java$kotlin$lua$zig$php$ruby\
[](fg:green bg:sapphire)\
$docker_context$container$conda$nix_shell\
[](fg:sapphire)\
$fill\
$status$cmd_duration$jobs$sudo$battery$memory_usage$time\
$line_break\
[╰─](fg:overlay1)$character"""

[fill]
symbol = " "

# --- Left: identity, location, git -----------------------------------------

[os]
disabled = false
style = "bg:red fg:crust"

[os.symbols]
Fedora = "\U000F08DB "
Linux = "\U000F033D "

[username]
show_always = true
style_user = "bg:red fg:crust"
style_root = "bg:red fg:crust bold"
format = "[$user]($style)"

# Only shown over SSH.
[hostname]
ssh_only = true
style = "bg:red fg:crust"
format = "[@$hostname]($style)"

[directory]
style = "bg:peach fg:crust"
read_only_style = "bg:peach fg:crust"
format = "[ $path ]($style)[$read_only]($read_only_style)"
read_only = " "
truncation_length = 4
truncation_symbol = "…/"

[directory.substitutions]
"Documents" = "\U000F0219 "
"Downloads" = " "
"Music" = "\U000F075A "
"Pictures" = " "
"projects" = "\U000F0C8B "

[git_branch]
symbol = ""
style = "bg:yellow fg:crust"
format = "[ $symbol $branch(:$remote_branch) ]($style)"

[git_state]
style = "bg:yellow fg:crust bold"
format = "[\\($state( $progress_current/$progress_total)\\) ]($style)"

[git_status]
style = "bg:yellow fg:crust"
format = "[($all_status$ahead_behind )]($style)"
ahead = "⇡${count}"
behind = "⇣${count}"
diverged = "⇕⇡${ahead_count}⇣${behind_count}"

[git_metrics]
disabled = false
added_style = "bg:yellow fg:crust"
deleted_style = "bg:yellow fg:crust"
format = "([+$added ]($added_style))([-$deleted ]($deleted_style))"

# --- Left: language toolchains ---------------------------------------------

[c]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[cpp]
disabled = false
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[rust]
symbol = "\U000F1617"
format = "[ $symbol( $version) ](fg:crust bg:green)"

[golang]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[nodejs]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[bun]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[deno]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[python]
symbol = ""
format = "[ $symbol( $version)( \\($virtualenv\\)) ](fg:crust bg:green)"

[java]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[kotlin]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[lua]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[zig]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[php]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

[ruby]
symbol = ""
format = "[ $symbol( $version) ](fg:crust bg:green)"

# --- Left: containers and environments -------------------------------------

[docker_context]
symbol = ""
format = "[ $symbol $context ](fg:crust bg:sapphire)"

# Toolbox / Distrobox / Podman containers.
[container]
symbol = ""
format = "[ $symbol $name ](fg:crust bg:sapphire)"

[conda]
symbol = ""
ignore_base = false
format = "[ $symbol $environment ](fg:crust bg:sapphire)"

[nix_shell]
symbol = ""
format = "[ $symbol $state( $name) ](fg:crust bg:sapphire)"

# --- Right: last command, session, system ----------------------------------

[status]
disabled = false
symbol = ""
format = "[](fg:red)[$symbol $status( $signal_name)](fg:crust bg:red)[](fg:red) "

[cmd_duration]
min_time = 2000
show_notifications = true
min_time_to_notify = 45000
format = "[](fg:mauve)[ $duration](fg:crust bg:mauve)[](fg:mauve) "

[jobs]
symbol = ""
number_threshold = 1
format = "[](fg:blue)[$symbol $number](fg:crust bg:blue)[](fg:blue) "

# Shown while sudo has cached credentials.
[sudo]
disabled = false
symbol = ""
format = "[](fg:maroon)[$symbol sudo](fg:crust bg:maroon)[](fg:maroon) "

[battery]
format = "[](fg:yellow)[$symbol$percentage](fg:crust bg:yellow)[](fg:yellow) "

[[battery.display]]
threshold = 30

[memory_usage]
disabled = false
threshold = -1
symbol = "\U000F035B"
format = "[](fg:teal)[$symbol $ram_pct](fg:crust bg:teal)[](fg:teal) "

[time]
disabled = false
time_format = "%R"
format = "[](fg:lavender)[ $time](fg:crust bg:lavender)[](fg:lavender)"

# --- Prompt line -------------------------------------------------------------

[line_break]
disabled = false

[character]
success_symbol = "[❯](bold fg:green)"
error_symbol = "[❯](bold fg:red)"
vimcmd_symbol = "[❮](bold fg:green)"
vimcmd_replace_one_symbol = "[❮](bold fg:lavender)"
vimcmd_replace_symbol = "[❮](bold fg:lavender)"
vimcmd_visual_symbol = "[❮](bold fg:yellow)"

[palettes.catppuccin_mocha]
rosewater = "#f5e0dc"
flamingo = "#f2cdcd"
pink = "#f5c2e7"
mauve = "#cba6f7"
red = "#f38ba8"
maroon = "#eba0ac"
peach = "#fab387"
yellow = "#f9e2af"
green = "#a6e3a1"
teal = "#94e2d5"
sky = "#89dceb"
sapphire = "#74c7ec"
blue = "#89b4fa"
lavender = "#b4befe"
text = "#cdd6f4"
subtext1 = "#bac2de"
subtext0 = "#a6adc8"
overlay2 = "#9399b2"
overlay1 = "#7f849c"
overlay0 = "#6c7086"
surface2 = "#585b70"
surface1 = "#45475a"
surface0 = "#313244"
base = "#1e1e2e"
mantle = "#181825"
crust = "#11111b"
EOF
}

is_stock_preset() {
  local p
  for p in $(starship preset --list); do
    starship preset "$p" | cmp -s - "$1" && return 0
  done
  return 1
}

# Our config replaces a missing file, a stock preset, or an earlier version of
# itself (with a .bak); a hand-edited config is left alone.
setup_starship() {
  local cfg="$HOME/.config/starship.toml" tmp
  have starship || return 1
  tmp=$(mktemp -p "$TMP_ROOT")
  starship_config > "$tmp"
  if [[ -f $cfg ]]; then
    if cmp -s "$tmp" "$cfg"; then
      rm -f "$tmp"
      return 0
    fi
    if [[ $(head -n1 "$cfg") != "$STARSHIP_MARKER" ]] && ! is_stock_preset "$cfg"; then
      rm -f "$tmp"
      echo "Keeping customized $cfg"
      return 0
    fi
    cp "$cfg" "$cfg.bak"
  fi
  install -m 0644 "$tmp" "$cfg"
}

setup_sshd_firewall() {
  dnf_install openssh-server
  sudo systemctl enable --now sshd || return 1
  if firewalld_running && ! sudo firewall-cmd --query-service=ssh >/dev/null 2>&1; then
    sudo firewall-cmd --permanent --add-service=ssh || return 1
    sudo firewall-cmd --reload || return 1
  fi
}

# Ask for a git identity field, defaulting to the GitHub profile value.
prompt_git_identity() {
  local key=$1 gh_field=$2 value input
  [[ -n $(git config --global "$key" || true) ]] && return 0
  value=$(gh api user --jq ".$gh_field // empty" 2>/dev/null || true)
  # The profile email is often private (null); fall back to GitHub's noreply address.
  if [[ -z $value && $key == user.email ]]; then
    value=$(gh api user --jq '"\(.id)+\(.login)@users.noreply.github.com"' 2>/dev/null || true)
  fi
  read -r -p "Git $key [$value]: " input || input=
  value=${input:-$value}
  [[ -z $value ]] || git config --global "$key" "$value"
}

setup_github() {
  have gh || dnf_install gh
  have gh || return 1
  if [[ ! -t 0 ]]; then
    warn "No interactive terminal; skipping GitHub login. Run later: gh auth login && gh auth setup-git"
    return 0
  fi
  if gh auth status >/dev/null 2>&1; then
    echo "gh is already authenticated."
  else
    gh auth login --git-protocol https --web || return 1
  fi
  gh auth setup-git || return 1
  prompt_git_identity user.name name
  prompt_git_identity user.email email
}

# ---------------------------------------------------------------------------
# Component selection
# ---------------------------------------------------------------------------

# With no selection flags, all components start selected. The interactive TUI
# lets terminal users adjust that set; non-interactive runs retain the old behavior.
# `--only` narrows execution; `--skip` removes components from the default set.
COMPONENTS=(
  dnf-config upgrade rpmfusion flatpak-remotes multimedia nvidia core extra
  desktop starship claudecode worktrunk dust docker wezterm lazygit zen localsend
  uv bun zed lazydocker toolbox nerd-font zsh-setup configs starship-theme
  sshd mok github flatpak-update ente-auth unity-hub
)

declare -A COMPONENT_DESCRIPTION=(
  [dnf-config]="Configure DNF download settings"
  [upgrade]="Refresh repositories and upgrade Fedora packages"
  [rpmfusion]="Enable RPM Fusion and OpenH264 repositories/packages"
  [flatpak-remotes]="Install Flatpak and configure Flathub/Fedora remotes"
  [multimedia]="Install full FFmpeg and multimedia codecs"
  [nvidia]="Detect NVIDIA hardware and install the appropriate driver"
  [core]="Install core command-line packages"
  [extra]="Install optional CLI packages"
  [desktop]="Install desktop-specific tools and Papirus icons"
  [starship]="Install the Starship prompt"
  [claudecode]="Install Claude Code"
  [worktrunk]="Install Worktrunk and its shell integration"
  [dust]="Install dust disk-usage utility"
  [docker]="Install Docker and enable its service"
  [wezterm]="Install WezTerm (COPR, with Flatpak fallback)"
  [lazygit]="Install Lazygit"
  [zen]="Install Zen Browser Flatpak"
  [localsend]="Install LocalSend Flatpak and open its discovery ports"
  [uv]="Install uv"
  [bun]="Install Bun"
  [zed]="Install Zed editor"
  [lazydocker]="Install Lazydocker"
  [toolbox]="Install JetBrains Toolbox"
  [nerd-font]="Install JetBrainsMono Nerd Font"
  [zsh-setup]="Configure Zsh, Oh My Zsh, and plugins"
  [configs]="Write Git, tmux, and WezTerm configuration files"
  [starship-theme]="Install the managed Starship theme configuration"
  [sshd]="Enable SSH server and open the SSH firewall service"
  [mok]="Enroll the NVIDIA Secure Boot signing key when required"
  [github]="Configure GitHub CLI authentication and Git identity"
  [flatpak-update]="Update installed Flatpak applications"
  [ente-auth]="Install Ente Auth 2FA authenticator"
  [unity-hub]="Install Unity Hub"
)

declare -A SELECTED_COMPONENTS=()
REQUESTED_ONLY=()
REQUESTED_SKIP=()
ONLY_WAS_USED=0
SHOW_COMPONENT_LIST=0
SHOW_HELP=0
FORCE_TUI=0
NO_TUI=0

add_component_names() {
  local mode=$1 value=$2 name
  local -a names=()
  IFS=',' read -r -a names <<< "$value"
  ((${#names[@]})) || die "Empty component list."
  for name in "${names[@]}"; do
    name=${name//[[:space:]]/}
    [[ -n $name ]] || die "Empty component name in: $value"
    case $mode in
      only) REQUESTED_ONLY+=("$name") ;;
      skip) REQUESTED_SKIP+=("$name") ;;
    esac
  done
}

usage() {
  cat <<'EOF'
Usage: ./fedora-setup.sh [OPTIONS]

Run the complete Fedora workstation setup by default, or choose components.

Options:
  -i, --interactive      Open the interactive component selector
  --no-tui               Run without the interactive selector
  --list                 List available components and their descriptions
  --only NAME[,NAME...]  Run only the specified component(s); use 'all' for all defaults
  --skip NAME[,NAME...]  Skip component(s); repeatable
  -h, --help             Show this help

When run in a terminal without --only/--skip, the selector opens by default.
When stdin or stdout is not a terminal, all default components run; sshd is opt-in.

Examples:
  ./fedora-setup.sh
  ./fedora-setup.sh --no-tui
  ./fedora-setup.sh --list
  ./fedora-setup.sh --only docker
  ./fedora-setup.sh --only all
  ./fedora-setup.sh --only docker,wezterm,zen
  ./fedora-setup.sh --skip nvidia,sshd
  ./fedora-setup.sh --only multimedia --skip nvidia

Component dependencies are enabled automatically when needed (for example,
multimedia enables RPM Fusion, and NVIDIA enables Secure Boot key enrollment).
A required dependency can be re-enabled even if it also appears in --skip.
sshd is opt-in; enabling Docker adds your user to the root-equivalent docker group.
EOF
}

list_components() {
  local name
  printf 'Available components (use --only or --skip):\n\n'
  for name in "${COMPONENTS[@]}"; do
    printf '  %-17s %s\n' "$name" "${COMPONENT_DESCRIPTION[$name]}"
  done
  printf '\nAll default components are selected except sshd, which is opt-in; the TUI lets you change this before running.\n'
}

parse_args() {
  while (($#)); do
    case $1 in
      --list) SHOW_COMPONENT_LIST=1; shift ;;
      -h|--help) SHOW_HELP=1; shift ;;
      -i|--interactive) FORCE_TUI=1; shift ;;
      --no-tui) NO_TUI=1; shift ;;
      --only)
        (($# >= 2)) || die "--only requires a component name."
        ONLY_WAS_USED=1
        add_component_names only "$2"
        shift 2
        ;;
      --skip)
        (($# >= 2)) || die "--skip requires a component name."
        add_component_names skip "$2"
        shift 2
        ;;
      --only=*)
        ONLY_WAS_USED=1
        add_component_names only "${1#*=}"
        shift
        ;;
      --skip=*)
        add_component_names skip "${1#*=}"
        shift
        ;;
      --) shift; (($# == 0)) || die "Unexpected positional arguments: $*" ;;
      -*) die "Unknown option: $1 (use --help)" ;;
      *) die "Unexpected argument: $1 (use --help)" ;;
    esac
  done
}

is_known_component() {
  local candidate=$1 name
  for name in "${COMPONENTS[@]}"; do
    [[ $candidate == "$name" ]] && return 0
  done
  return 1
}

is_selected() {
  [[ ${SELECTED_COMPONENTS[$1]:-0} == 1 ]]
}

resolve_selection() {
  local name selected_count=0
  for name in "${COMPONENTS[@]}"; do SELECTED_COMPONENTS[$name]=0; done

  if ((ONLY_WAS_USED)); then
    for name in "${REQUESTED_ONLY[@]}"; do
      [[ $name == all ]] && continue
      is_known_component "$name" || die "Unknown component: $name (use --list)"
      SELECTED_COMPONENTS[$name]=1
    done
    for name in "${REQUESTED_ONLY[@]}"; do
      if [[ $name == all ]]; then
        for name in "${COMPONENTS[@]}"; do SELECTED_COMPONENTS[$name]=1; done
        SELECTED_COMPONENTS[sshd]=0
        break
      fi
    done
  else
    for name in "${COMPONENTS[@]}"; do SELECTED_COMPONENTS[$name]=1; done
    # Starting an SSH server is a deliberate opt-in on a workstation.
    SELECTED_COMPONENTS[sshd]=0
  fi

  for name in "${REQUESTED_SKIP[@]}"; do
    is_known_component "$name" || die "Unknown component: $name (use --list)"
    SELECTED_COMPONENTS[$name]=0
  done

  # Add prerequisites for components that cannot operate independently.
  if is_selected multimedia || is_selected nvidia; then
    SELECTED_COMPONENTS[rpmfusion]=1
  fi
  # NVIDIA on Secure Boot may require MOK enrollment; enroll_mok is a no-op
  # when Secure Boot is disabled or the key is already enrolled.
  if is_selected nvidia; then
    SELECTED_COMPONENTS[mok]=1
  fi
  if is_selected zen || is_selected localsend || is_selected wezterm || is_selected ente-auth; then
    SELECTED_COMPONENTS[flatpak-remotes]=1
  fi
  if is_selected starship-theme; then
    SELECTED_COMPONENTS[starship]=1
  fi
  if is_selected zsh-setup || is_selected configs; then
    SELECTED_COMPONENTS[core]=1
  fi

  for name in "${COMPONENTS[@]}"; do
    (( ${SELECTED_COMPONENTS[$name]} )) && ((selected_count += 1))
  done
  ((selected_count > 0)) || die "No components selected."
}

# Restore terminal settings after the interactive selector (also called by EXIT cleanup).
tui_restore_terminal() {
  if [[ -n ${TUI_STTY_STATE:-} ]]; then
    stty "$TUI_STTY_STATE" 2>/dev/null || true
    TUI_STTY_STATE=
  fi
  printf '\033[?25h' 2>/dev/null || true
}

# Interactive checkbox selector. Uses Bash + stty only; no dialog/gum dependency.
select_components_tui() {
  [[ -t 0 && -t 1 ]] || die "The interactive selector requires a terminal (TTY)."

  local total=${#COMPONENTS[@]} current=0 top=0 rows cols page_size desc_width
  local key seq1 seq2 seq3 name desc marker pointer selected_count end_index i message=
  rows=$(tput lines 2>/dev/null || printf '24')
  cols=$(tput cols 2>/dev/null || printf '80')
  [[ $rows =~ ^[0-9]+$ ]] || rows=24
  [[ $cols =~ ^[0-9]+$ ]] || cols=80
  page_size=$((rows - 7))
  ((page_size < 3)) && page_size=3
  desc_width=$((cols - 26))
  ((desc_width < 12)) && desc_width=12

  TUI_STTY_STATE=$(stty -g) || die "Unable to read terminal settings."
  stty -echo -icanon min 1 time 0 || die "Unable to configure terminal input."
  printf '\033[?25l'

  while :; do
    selected_count=0
    for name in "${COMPONENTS[@]}"; do
      if (( ${SELECTED_COMPONENTS[$name]:-0} )); then
        selected_count=$((selected_count + 1))
      fi
    done

    # Keep the focused row inside the visible viewport.
    ((current < top)) && top=$current
    ((current >= top + page_size)) && top=$((current - page_size + 1))
    end_index=$((top + page_size))
    ((end_index > total)) && end_index=$total

    printf '\033[H\033[2J'
    printf '\033[1;36mFedora Workstation Setup\033[0m\n'
    printf 'Select the components to install or configure.\n'
    printf 'Selected: %d / %d\n\n' "$selected_count" "$total"

    for ((i = top; i < end_index; i++)); do
      name=${COMPONENTS[$i]}
      desc=${COMPONENT_DESCRIPTION[$name]}
      marker=' '
      pointer=' '
      (( ${SELECTED_COMPONENTS[$name]:-0} )) && marker='x'
      ((i == current)) && pointer='>'
      if ((${#desc} > desc_width)); then
        desc="${desc:0:desc_width-1}…"
      fi
      if ((i == current)); then
        printf '\033[1;36m%s [%s] %-17s %s\033[0m\n' "$pointer" "$marker" "$name" "$desc"
      else
        printf ' %s [%s] %-17s %s\n' "$pointer" "$marker" "$name" "$desc"
      fi
    done

    printf '\n\033[2m↑/↓ or j/k: move   Space: toggle   a: all   n: none   Enter: confirm   q: cancel\033[0m\n'
    printf '\033[2mRequired dependencies are automatically selected.\033[0m\n'
    [[ -z $message ]] || printf '\033[1;33m%s\033[0m\n' "$message"
    message=

    IFS= read -rsn1 key
    case $key in
      $'\033')
        # Read a CSI arrow-key sequence without blocking on a lone Escape key.
        if IFS= read -rsn1 -t 0.08 seq1; then
          case $seq1 in
            '[')
              if IFS= read -rsn1 -t 0.08 seq2; then
                case $seq2 in
                  A) ((current > 0)) && current=$((current - 1)) ;;
                  B) ((current < total - 1)) && current=$((current + 1)) ;;
                  H) current=0 ;;
                  F) current=$((total - 1)) ;;
                  1|4)
                    if IFS= read -rsn1 -t 0.08 seq3 && [[ $seq3 == '~' ]]; then
                      [[ $seq2 == 1 ]] && current=0 || current=$((total - 1))
                    fi
                    ;;
                esac
              fi
              ;;
            O)
              if IFS= read -rsn1 -t 0.08 seq2; then
                case $seq2 in
                  A) ((current > 0)) && current=$((current - 1)) ;;
                  B) ((current < total - 1)) && current=$((current + 1)) ;;
                  H) current=0 ;;
                  F) current=$((total - 1)) ;;
                esac
              fi
              ;;
          esac
        fi
        ;;
      k|K) ((current > 0)) && current=$((current - 1)) ;;
      j|J) ((current < total - 1)) && current=$((current + 1)) ;;
      ' ')
        name=${COMPONENTS[$current]}
        if (( ${SELECTED_COMPONENTS[$name]:-0} )); then
          SELECTED_COMPONENTS[$name]=0
        else
          SELECTED_COMPONENTS[$name]=1
        fi
        ;;
      a|A)
        for name in "${COMPONENTS[@]}"; do SELECTED_COMPONENTS[$name]=1; done
        ;;
      n|N)
        for name in "${COMPONENTS[@]}"; do SELECTED_COMPONENTS[$name]=0; done
        ;;
      ''|$'\r'|$'\n')
        if ((selected_count == 0)); then
          message='Select at least one component before confirming.'
          continue
        fi
        REQUESTED_ONLY=()
        REQUESTED_SKIP=()
        for name in "${COMPONENTS[@]}"; do
          (( ${SELECTED_COMPONENTS[$name]:-0} )) && REQUESTED_ONLY+=("$name")
        done
        ONLY_WAS_USED=1
        tui_restore_terminal
        printf '\033[H\033[2J'
        log "Selection confirmed: $selected_count component(s)"
        return 0
        ;;
      q|Q)
        tui_restore_terminal
        printf '\033[H\033[2J'
        echo "Selection cancelled; nothing was changed."
        return 130
        ;;
    esac
  done
}

run_component() {
  local name=$1 title=$2
  shift 2
  is_selected "$name" || return 0
  step "$title" "$name" "$@"
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

print_summary() {
  echo
  if ((${#FAILED[@]})); then
    echo "Fedora setup finished with problems."
    warn "These steps had problems: ${FAILED[*]}"
    warn "Scroll up for details; the script is safe to re-run."
  else
    echo "Fedora setup completed."
  fi
  if ((NV_REBOOT)); then
    echo
    echo "NVIDIA: driver installed. Reboot to load it, then verify with: nvidia-smi"
    if ((HYBRID)); then
      echo "Hybrid GPU: run apps on the NVIDIA GPU with 'prime-run <app>' (or the discrete-GPU option in the app menu)."
    fi
    if ((NEEDS_MOK)); then
      echo "Secure Boot: at the reboot screen choose 'Enroll MOK' -> Continue -> Yes, then enter the password you set."
    fi
  fi
  # Only mention next steps for things that were actually selected.
  local reasons=() joined
  ((NV_REBOOT)) && reasons+=("the NVIDIA driver")
  is_selected zsh-setup && reasons+=("zsh as your login shell")
  is_selected docker && reasons+=("the docker group (equivalent to root access)")
  echo
  echo "Next steps:"
  if ((${#reasons[@]})); then
    joined=$(printf '%s, ' "${reasons[@]}")
    echo "  - Reboot (or log out and back in) to pick up: ${joined%, }."
  fi
  if is_selected toolbox; then
    echo '  - Launch "JetBrains Toolbox" once from your app menu; it installs itself and keeps itself updated.'
  fi
  if is_selected github; then
    echo "  - If the GitHub step was skipped or failed: gh auth login && gh auth setup-git"
  fi
  if is_selected nerd-font; then
    echo '  - In terminals other than WezTerm, set the font to "JetBrainsMono Nerd Font" so --icons render.'
  fi
  echo "  - Re-run with --list to see components you can add later (for example: --only docker)."
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  parse_args "$@"
  if ((SHOW_HELP)); then
    usage
    return 0
  fi
  if ((SHOW_COMPONENT_LIST)); then
    list_components
    return 0
  fi
  ((FORCE_TUI && NO_TUI)) && die "--interactive and --no-tui cannot be used together."

  # Validate the host and set architecture-specific download keys before install.
  check_environment

  # Open the selector by default for an interactive run. Explicit --only/--skip
  # remains non-interactive unless --interactive is supplied.
  if ((FORCE_TUI)) || { (( !NO_TUI && !ONLY_WAS_USED && ${#REQUESTED_SKIP[@]} == 0 )) && [[ -t 0 && -t 1 ]]; }; then
    resolve_selection
    select_components_tui || {
      local rc=$?
      ((rc == 130)) && return 0
      return "$rc"
    }
  fi
  resolve_selection
  preflight

  run_component dnf-config "Configuring DNF" configure_dnf
  run_component upgrade "Updating Fedora" do_upgrade
  run_component rpmfusion "Enabling RPM Fusion and standard repos" enable_repos
  run_component flatpak-remotes "Configuring Flatpak remotes (Flathub + Fedora)" configure_flatpak

  # Install selected components in dependency-friendly order.
  run_component multimedia "Installing full FFmpeg and multimedia support" install_multimedia
  run_component nvidia "Detecting NVIDIA GPU and installing its driver" setup_nvidia
  run_component core "Installing core packages" install_core
  run_component extra "Installing extra CLI tools" install_extra_packages
  run_component desktop "Configuring desktop-specific tools" setup_desktop
  run_component starship "Installing Starship" install_starship
  run_component claudecode "Installing Claude Code" install_claudecode
  run_component worktrunk "Installing Worktrunk" install_worktrunk
  run_component dust "Installing dust" install_dust
  run_component docker "Installing Docker" install_docker
  run_component wezterm "Installing WezTerm" install_wezterm
  run_component lazygit "Installing Lazygit" install_lazygit
  run_component zen "Installing Zen Browser" install_zen
  run_component localsend "Installing LocalSend" install_localsend
  run_component uv "Installing uv" install_uv
  run_component bun "Installing Bun" install_bun
  run_component zed "Installing Zed" install_zed
  run_component lazydocker "Installing Lazydocker" install_lazydocker
  run_component toolbox "Installing JetBrains Toolbox" install_toolbox
  run_component nerd-font "Installing JetBrainsMono Nerd Font" install_nerd_font
  run_component zsh-setup "Configuring Zsh / Oh My Zsh" setup_shell
  run_component configs "Writing Git/tmux/WezTerm configs" setup_configs
  run_component starship-theme "Theming the Starship prompt" setup_starship
  run_component sshd "Enabling sshd and opening the SSH firewall service" setup_sshd_firewall
  run_component mok "Secure Boot key enrollment (only if needed)" enroll_mok
  run_component github "Setting up GitHub CLI and Git identity" setup_github
  run_component flatpak-update "Updating Flatpak applications" update_flatpak
  run_component ente-auth "Installing Ente Auth" install_ente_auth
  run_component unity-hub "Installing Unity Hub" install_unity_hub

  print_summary
  # Non-zero exit when any best-effort component failed, so wrappers/CI can tell.
  ((${#FAILED[@]} == 0))
}

main "$@"
