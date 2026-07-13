{
  config,
  self,
  pkgs,
  lib,
  ...
}:
let
  fabroLib = import ./fabro-lib.nix { inherit self lib; };
in
{
  # Dedicated service identity shared by the Fabro server (Task 4) and the
  # nightly batch (Task 5, which drops to this user for `fabro` subcommands).
  users.users.fabro = {
    isSystemUser = true;
    group = "fabro";
    home = "/var/lib/fabro";
  };
  users.groups.fabro = { };

  # WARNING: night_llm_repos, night_llm_github_token, and fabro_dev_token MUST
  # exist in secrets/secrets.yaml (added via `sops` + `sops updatekeys`) BEFORE
  # `nixos-rebuild switch`, otherwise sops-install-secrets fails the WHOLE host
  # activation — taking down the runner + dockerhub secrets in the same file,
  # not just Fabro.
  sops.secrets.night_llm_repos = {
    owner = "fabro";
    group = "fabro";
    mode = "0400";
  };
  sops.secrets.night_llm_github_token = {
    owner = "fabro";
    group = "fabro";
    mode = "0400";
  };
  sops.secrets.fabro_dev_token = {
    owner = "fabro";
    group = "fabro";
    mode = "0400";
  };

  # Static, read-only Fabro settings. Ollama is an OpenAI-compatible provider with
  # no auth; the model default routes every workflow node to the local model.
  environment.etc."fabro/settings.toml".text = ''
    [server.listen]
    bind = "127.0.0.1:3000"

    [server.web]
    url = "https://nixos.tail411887.ts.net"

    [server.auth]
    methods = ["dev-token"]

    [llm.providers.ollama]
    adapter  = "openai_compatible"
    base_url = "http://127.0.0.1:11434/v1"

    [[llm.models]]
    provider = "ollama"
    api_id   = "${fabroLib.modelTag}"
    default  = true

    [run.model]
    provider = "ollama"

    [server.sandbox.providers.docker]
    enabled = true
  '';

  systemd.services.fabro = {
    description = "Fabro server (local UI + run store)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "network-online.target"
      "ollama.service"
    ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      User = "fabro";
      Group = "fabro";
      StateDirectory = "fabro";
      WorkingDirectory = "/var/lib/fabro";
      Environment = [ "HOME=/var/lib/fabro" ];
      # Seed the stable dev-token from sops before the server starts.
      ExecStartPre = "${pkgs.coreutils}/bin/install -Dm400 -o fabro -g fabro ${config.sops.secrets.fabro_dev_token.path} /var/lib/fabro/dev-token";
      # bind + web url come from settings.toml (single authority); only pass
      # what settings.toml can't express.
      ExecStart = "${fabroLib.fabroExe} server start --web --storage-dir /var/lib/fabro/storage --config /etc/fabro/settings.toml";
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  # Publish the loopback server on the tailnet with Tailscale-provisioned HTTPS.
  systemd.services.fabro-serve = {
    description = "Expose Fabro over Tailscale (HTTPS)";
    wantedBy = [ "multi-user.target" ];
    after = [
      "tailscaled.service"
      "fabro.service"
    ];
    wants = [
      "tailscaled.service"
      "fabro.service"
    ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.tailscale}/bin/tailscale serve --bg --https=443 http://127.0.0.1:3000";
      ExecStop = "${pkgs.tailscale}/bin/tailscale serve --https=443 off";
    };
  };
}
