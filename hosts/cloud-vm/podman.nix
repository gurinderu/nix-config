# Rootless podman for the login user, Docker-compatible: projects that run
# `docker compose up -d …` and `docker exec …` work unchanged, without a root
# daemon. What NixOS's virtualisation.podman (dockerCompat) gives, here from
# home-manager's services.podman plus:
#
# - `docker` is podman under that name (dockerCompat), so `docker compose`
#   is `podman compose`, which runs docker-compose (pinned below, also on
#   PATH) against podman's API socket;
# - podman.socket from the podman package's own user units, enabled through
#   sockets.target, with DOCKER_HOST pointing at it for other Docker API
#   clients (lingering keeps the user manager, and so the socket, up without
#   a login);
# - policy.json accepts any image like NixOS's default, and short names
#   (`postgres:16`) resolve on docker.io.
#
# Root side: newuidmap/newgidmap must be setuid, which nix cannot do here.
# They come from apt `uidmap` in /usr/bin (the bootstrap installs it), and
# /etc/subuid and /etc/subgid map the user (ubuntu:100000:65536 on Ubuntu's
# images). Rootless networking is podman 5's default pasta; ports published
# on 127.0.0.1 are reachable from the host.
#
# Check: `docker version` prints "Client: Podman Engine" (podman runs
# containers itself, so there is no Server section); `curl -s --unix-socket
# $XDG_RUNTIME_DIR/podman/podman.sock http://d/_ping` prints OK. A new
# DOCKER_HOST reaches only fresh logins: hm-session-vars.sh is sourced once
# per session tree.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  podman = config.services.podman.package;
  dockerCompat = pkgs.runCommand "podman-docker-compat" { } ''
    mkdir -p $out/bin $out/share/zsh/site-functions
    ln -s ${podman}/bin/podman $out/bin/docker
    # zsh completion for the `docker` name, as NixOS's dockerCompat makes it:
    # podman names the completed command after argv[0].
    HOME=$TMPDIR $out/bin/docker completion zsh > $out/share/zsh/site-functions/_docker
  '';
  allowAll = [ { type = "insecureAcceptAnything"; } ];
in
{
  services.podman = {
    enable = true;
    # Only acts on containers labelled for it; none are.
    autoUpdate.enable = false;
    settings = {
      policy = {
        default = allowAll;
        transports.docker-daemon."" = allowAll;
      };
      containers.engine = {
        compose_providers = [ "${pkgs.docker-compose}/bin/docker-compose" ];
        # Drops the ">>>> Executing external compose provider" banner.
        compose_warning_logs = false;
      };
    };
  };

  # The module writes the deprecated v1 [registries.search] table; podman's
  # own format (v2) instead.
  xdg.configFile."containers/registries.conf".source = lib.mkForce (
    (pkgs.formats.toml { }).generate "registries.conf" {
      unqualified-search-registries = [ "docker.io" ];
    }
  );

  home.packages = [
    dockerCompat
    pkgs.docker-compose
  ];

  systemd.user.packages = [ podman ];
  xdg.configFile."systemd/user/sockets.target.wants/podman.socket".source =
    "${podman}/share/systemd/user/podman.socket";

  home.sessionVariables.DOCKER_HOST = "unix://$XDG_RUNTIME_DIR/podman/podman.sock";
}
