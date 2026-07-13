#your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
{
  imports = [
    # Include the results of the hardware scan.
    ./hardware-configuration.nix
    ./sing-box.nix
    ./github-runner.nix
    ./fabro.nix
    ./night-llm.nix
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  boot = {
    plymouth = {
      enable = true;
    };
    # plymouth splash; "quiet" is already set in hardware-configuration.nix
    kernelParams = [ "splash" ];
    loader = {
      efi.canTouchEfiVariables = true;
      grub = {
        configurationLimit = 3;
        enable = true;
        efiSupport = true;
        device = "nodev";
        useOSProber = true;
        # grub.cfg directives (not /etc/default/grub vars): set the EFI
        # framebuffer mode and keep it for a HiDPI boot console.
        gfxmodeEfi = "2880x1800x120";
        gfxpayloadEfi = "keep";
        extraEntries = ''
          				menuentry "Reboot" {
          					reboot
          				}
          				menuentry "Poweroff" {
          					halt
          				}
          			'';
      };
    };
  };

  networking.hostName = "nixos"; # Define your hostname.

  hardware.graphics.enable = true;
  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;

  services.blueman.enable = true;
  services.desktopManager.cosmic.enable = true;
  services.displayManager.cosmic-greeter.enable = true;

  # Set your time zone.
  time.timeZone = "Europe/Moscow";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.supportedLocales = [
    "en_US.UTF-8/UTF-8"
    "ru_RU.UTF-8/UTF-8"
  ];
  console = {
    # font = "JetBrainsMono";
    # keyMap = "us,ru";
    useXkbConfig = true; # use xkb.options in tty.
  };

  # Enable the X11 windowing system.
  services.xserver = {
    enable = true;
  };
  security.rtkit.enable = true;
  programs.zsh.enable = true;

  nixpkgs.config.allowUnfree = true;
  fonts = {
    fontDir.enable = true;
    fontconfig.cache32Bit = true;
    fontconfig.defaultFonts.monospace = [ "JetBrainsMono" ];
    packages = with pkgs; [
      corefonts
      helvetica-neue-lt-std
      jetbrains-mono
    ];
  };

  # Configure keymap in X11
  services.xserver.xkb.layout = "us,ru";
  services.xserver.xkb.options = "eurosign:e,caps:escape,grp:alt_shift_toggle";

  # Enable CUPS to print documents.
  # services.printing.enable = true;

  # Enable sound.
  # hardware.pulseaudio.enable = true;
  # OR
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  services.libinput.enable = true;
  services.libinput.touchpad.naturalScrolling = true;

  virtualisation = {
    podman = {
      enable = true;
      dockerCompat = true; # `docker` command -> podman (for the interactive user)
      dockerSocket.enable = true; # docker-compatible socket at /run/docker.sock
      defaultNetwork.settings.dns_enabled = true; # DNS between containers
    };
    libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        swtpm.enable = true;
      };
    };
    spiceUSBRedirection.enable = true;
  };
  users.groups.plugdev = { };
  # Define a user account. Don't forget to set a password with ‘passwd’.
  users.users."0xff" = {
    shell = pkgs.zsh;
    isNormalUser = true;
    extraGroups = [
      "wheel"
      "networkmanager"
      "podman"
      "plugdev"
      "libvirtd"
    ]; # Enable ‘sudo’ for the user.
    # SSH login is key-only (PasswordAuthentication is off below), so these keys are
    # the only way in over the network. Keep at least one valid here before rebuilding.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJg3zeRwFNvTDDCm2mWv3LvEYmeTkxaQz/voFq15GIa8 gurinderu@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSzfNMFQnQ5yUJ8lX/gYiFWJXfrZqc88Fw+1c1OyE03 gurinderu@Nicks-MacBook-Air.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINYRRRC4FS1QKa6M+JCtqkFRY4jhP6NvPwTpUVh5Z9Zf iphone"
    ];
  };
  programs.nix-ld.enable = true;
  programs.nix-ld.libraries = with pkgs; [
    wayland
    libxkbcommon
    freetype
    fontconfig
  ];
  # Mirror PATH into /bin and /usr/bin via a FUSE filesystem so foreign scripts
  # with hard-coded shebangs resolve on NixOS. Needed e.g. by the Claude Code
  # semgrep plugin, whose hook.sh starts with `#!/bin/bash` (absent on NixOS);
  # without this its MCP server fails to spawn with ENOENT.
  services.envfs.enable = true;
  home-manager.users."0xff" =
    { pkgs, ... }:
    {
      imports = [
        ../../users/common/home.nix
        ./opencode.nix
      ];
      # Common dev tools + zsh/git/neovim/starship/direnv/zellij come from
      # ../../users/common/home.nix. Only thinkpad-specific packages live here.
      home.packages = [
        pkgs.firefox
        pkgs.lastpass-cli
        pkgs.wl-clipboard
        pkgs.playerctl
        pkgs.gh-dash
        pkgs.imv
        pkgs.k9s
        pkgs.mpv
        pkgs.warp-terminal
        pkgs.yazi
        pkgs.zathura
        pkgs.telegram-desktop
        pkgs.slack
        pkgs.zoom-us
        pkgs.sing-box
        pkgs.bash
        pkgs.mold
        pkgs.jetbrains-toolbox
        pkgs.llvm_18
        pkgs.clang_18
        pkgs.pamixer
        pkgs.mpc
      ];

      programs.zed-editor.enable = true;
      programs.vscode.enable = true;
      programs.alacritty.enable = true;

      home.stateVersion = "24.11";
    };
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "bak";
  home-manager.extraSpecialArgs = { inherit inputs; };
  users.defaultUserShell = pkgs.zsh;

  systemd.services.NetworkManager-wait-online.enable = false;
  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim # Do not forget to add an editor to edit configuration.nix! The Nano editor is also installed by default.
    bash
    wget
    xwayland
    gnugrep
    coreutils
    kitty
    qemu
    iptables
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  # List services that you want to enable:

  # Enable the OpenSSH daemon. Key-only: no passwords, no root login.
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  # Tailscale: stable reach into this roaming laptop from any network (no dependence on
  # the DHCP LAN IP). The firewall IS enabled (see networking.firewall below), so
  # Tailscale's WireGuard UDP port is opened via services.tailscale.openFirewall.
  # Auth is done once manually (`sudo tailscale up`) with key expiry disabled in the
  # admin console — no authKeyFile so rebuilds never fail on an expired/used key.
  services.tailscale.enable = true;

  # This laptop doubles as a CI runner: stay awake on AC / docked so the runner and SSH
  # remain reachable; still suspend on lid-close while on battery. NOTE: COSMIC may run
  # its own idle-suspend — if it still sleeps on AC, disable that in the DE power settings.
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "ignore";
    HandleLidSwitchDocked = "ignore";
  };

  # Firewall: allow established/related, block unsolicited inbound on all
  # interfaces. checkReversePath=false is required so WireGuard return packets
  # (Tailscale) are not dropped by reverse-path filtering.
  # nftables is left off — sing-box auto_route uses iptables rules; mixing
  # nftables and iptables on the same host causes rule evaluation conflicts.
  # openFirewall opens Tailscale's WireGuard UDP port so peers can initiate
  # connections to this node (needed when NAT traversal relies on direct UDP).
  # tun0 is sing-box's TUN inbound: response packets from VLESS arrive on this
  # interface and must reach local sockets — trustedInterfaces bypasses the
  # INPUT chain for tun0 so the firewall doesn't drop these reply packets.
  networking.firewall.enable = true;
  networking.firewall.checkReversePath = false;
  networking.firewall.allowedTCPPorts = [ 22 ]; # SSH — key-only auth
  networking.firewall.trustedInterfaces = [ "tun0" ];
  networking.nftables.enable = false;
  services.tailscale.openFirewall = true;

  networking.networkmanager.enable = true;

  # Copy the NixOS configuration file and link it from the resulting system
  # (/run/current-system/configuration.nix). This is useful in case you
  # accidentally delete configuration.nix.
  # system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  #
  # Most users should NEVER change this value after the initial install, for any reason,
  # even if you've upgraded your system to a new NixOS release.
  #
  # This value does NOT affect the Nixpkgs version your packages and OS are pulled from,
  # so changing it will NOT upgrade your system - see https://nixos.org/manual/nixos/stable/#sec-upgrading for how
  # to actually do that.
  #
  # This value being lower than the current NixOS release does NOT mean your system is
  # out of date, out of support, or vulnerable.
  #
  # Do NOT change this value unless you have manually inspected all the changes it would make to your configuration,
  # and migrated your data accordingly.
  #
  # For more information, see `man configuration.nix` or https://nixos.org/manual/nixos/stable/options#opt-system.stateVersion .
  system.stateVersion = "24.05"; # Did you read the comment?

}
