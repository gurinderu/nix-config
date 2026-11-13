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
    ./local-agents.nix
    # osewa server for 0xff (persistent terminals, next to mosh), its
    # linger and its tailnet-only ports.
    ./osewa.nix
    # moshi-hook daemon for the Moshi app, linked into ~/.local/bin.
    ./moshi-hook.nix
    # herdr for 0xff, as on cloud-vm: ssh, mosh and osewa logins attach to
    # it; memory-capped server unit and tab-title plugin.
    ./herdr.nix
    # `safe-switch`: a switch that survives a dropped ssh session and rolls
    # itself back unless confirmed (README "Rebuild").
    ./safe-switch.nix
  ];

  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];
  # Keep the store from growing without bound: weekly GC of generations older
  # than two weeks (systemd timer), plus hard-link dedup of new store paths.
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 14d";
  };
  # Dedup at write time, not with the periodic nix-optimise run: that one
  # re-links existing store files, changing their inodes under the runner
  # microVMs that share /nix/store over virtiofs, and the guests then get
  # ESTALE on store files until restarted (see github-runner-vm.nix).
  nix.optimise.automatic = false;
  nix.settings.auto-optimise-store = true;

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
    # Host podman is the interactive user's only: the CI runners moved into
    # microVMs with their own rootless podman (github-runner.nix) and no
    # longer touch this socket.
    #
    # Pin the subnet pool for user-created networks (`docker network create`,
    # compose, Testcontainers) to 10.89.0.0/16 so it stays inside the
    # 10.88.0.0/15 that sing-box's TUN excludes (users/gurinderu/
    # sing-box-config-linux.nix). netavark's built-in pool would otherwise
    # spill into 10.90.0.0/15 and beyond, which auto_route sends to tun0.
    # Its top /24, 10.89.255.0/24, carries the runner VMs' taps; netavark
    # skips subnets already live on an interface.
    containers.containersConf.settings.network.default_subnet_pools = [
      {
        base = "10.89.0.0/16";
        size = 24;
      }
    ];
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
      # Read the system journal without sudo (`journalctl -u microvm@warp-1`),
      # for maintenance from the cloud VM over SSH. Deliberately not a sudo
      # rule: journalctl's pager is a shell escape, so sudo journalctl = root.
      "systemd-journal"
    ]; # Enable ‘sudo’ for the user.
    # SSH login is key-only (PasswordAuthentication is off below), so these keys are
    # the only way in over the network. Keep at least one valid here before rebuilding.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJg3zeRwFNvTDDCm2mWv3LvEYmeTkxaQz/voFq15GIa8 gurinderu@gmail.com"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHSzfNMFQnQ5yUJ8lX/gYiFWJXfrZqc88Fw+1c1OyE03 gurinderu@Nicks-MacBook-Air.local"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINYRRRC4FS1QKa6M+JCtqkFRY4jhP6NvPwTpUVh5Z9Zf iphone"
    ];
  };
  # Passwordless maintenance for 0xff, used from the cloud VM over SSH. Only
  # exact commands with exact arguments: sudo's `*` in arguments also matches
  # spaces, so a wildcard would admit any extra flag. No nixos-rebuild (a
  # deploy runs arbitrary activation scripts as root) and no journalctl (its
  # pager is a shell escape; the systemd-journal group above covers reading).
  # Per-VM restart rules for the runner microVMs live in github-runner.nix.
  #
  # The store path still matches a plain `sudo podman ...`: sudo resolves
  # `podman` via PATH to /run/current-system/sw/bin/podman, and when the
  # basenames agree it compares the sudoers path and the user's command by
  # stat() device and inode, which follows the symlink into this same store
  # path (the sudoers file and the system profile come from one generation).
  security.sudo.extraRules = [
    {
      users = [ "0xff" ];
      commands = [
        {
          # Reclaim the root podman store (images, build cache, volumes).
          command = "${config.virtualisation.podman.package}/bin/podman system prune --all --volumes --force";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];
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
        ./claude-code.nix
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
        # Stable's 3.1.0 tarball is gone from download-cdn.jetbrains.com (404);
        # build unstable's recipe with stable pkgs until stable catches up.
        (pkgs.callPackage "${inputs.nixpkgs-unstable}/pkgs/by-name/je/jetbrains-toolbox/package.nix" { })
        pkgs.llvm_18
        pkgs.clang_18
        pkgs.pamixer
        pkgs.mpc
      ];

      programs.zed-editor.enable = true;
      programs.alacritty.enable = true;

      home.stateVersion = "24.11";
    };
  home-manager.useGlobalPkgs = true;
  home-manager.useUserPackages = true;
  home-manager.backupFileExtension = "bak";
  # Replace a stale *.bak from an earlier activation instead of aborting the
  # switch with "would be clobbered" when the same file collides again.
  home-manager.overwriteBackup = true;
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
  # A switch that changes tailscaled's unit (a tailscale bump) must not
  # restart it: ssh and mosh into this laptop ride tailscale, so the restart
  # drops the session that runs the switch. A new tailscale version applies
  # on reboot or after a manual `sudo systemctl restart tailscaled` (from a
  # local terminal or inside `safe-switch`'s rollback window).
  systemd.services.tailscaled.restartIfChanged = false;

  # Firmware updates via LVFS (`fwupdmgr refresh && fwupdmgr update`); the
  # X1 gen 12's BIOS, EC, Thunderbolt and fingerprint reader all ship there.
  services.fwupd.enable = true;

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

  # mosh: client and server come from users/common/home.nix. Its UDP range is
  # open on the tailnet only, so mosh reaches this laptop over tailscale and
  # nowhere else (ssh itself stays open everywhere, as above).
  networking.firewall.interfaces.tailscale0.allowedUDPPortRanges = [
    {
      from = 60000;
      to = 61000;
    }
  ];

  networking.networkmanager.enable = true;
  # Same for the links under tailscale: NixOS restarts NetworkManager (on a
  # change of its unit or NetworkManager.conf) and wpa_supplicant (on a
  # change of its unit) during a switch by default; the wpa_supplicant
  # restart drops the wifi association. Their changes apply on reboot or a
  # manual `systemctl restart`. sshd needs nothing: NixOS gives it
  # KillMode=process and stopIfChanged=false, so a restart keeps sessions.
  systemd.services.NetworkManager.restartIfChanged = false;
  systemd.services.wpa_supplicant.restartIfChanged = false;

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
