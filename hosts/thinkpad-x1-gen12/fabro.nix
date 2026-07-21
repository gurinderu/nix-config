{
  config,
  self,
  pkgs,
  lib,
  ...
}:
let
  fabroLib = import ./fabro-lib.nix { inherit self lib; };
  # Fabro derives its (writable) config dir from --config's parent and creates
  # subdirs like environments/ there, so the settings file must live in a
  # fabro-owned dir — NOT read-only /etc. Rendered to the store, then installed
  # into /var/lib/fabro by ExecStartPre.
  settingsToml = pkgs.writeText "fabro-settings.toml" ''
    _version = 1

    [server.listen]
    type = "tcp"
    address = "127.0.0.1:3000"

    [server.web]
    enabled = true
    url = "https://nixos.tail411887.ts.net"

    [server.auth]
    methods = ["dev-token"]

    # Local model served by ollama, exposed to fabro through its BUILT-IN
    # `openai` provider re-pointed at ollama's OpenAI-compatible endpoint.
    # A custom `[llm.providers.ollama]` does NOT work: fabro puts the model in
    # its catalog but never registers the custom provider ("Provider 'ollama'
    # not registered" at inference), and its "at least one provider configured"
    # gate only recognises built-in providers' keys. So we repoint `openai` and
    # give it a dummy key (OPENAI_API_KEY in the service env below; ollama
    # ignores it). A custom model must supply family/display_name/limits/
    # features or the catalog build fails at server startup. `default` is
    # omitted — openai already has a default (gpt-*); the run selects this model
    # explicitly via [run.model].
    [llm.providers.openai]
    base_url = "http://127.0.0.1:11434/v1"

    [llm.models."qwen36-local"]
    provider     = "openai"
    api_id       = "${fabroLib.modelTag}"
    family       = "qwen"
    display_name = "Qwen3.6 35B Local"
    enabled      = true

    [llm.models."qwen36-local".limits]
    context_window = 32768
    max_output     = 8192

    [llm.models."qwen36-local".features]
    tools        = true
    vision       = false
    reasoning    = true
    prompt_cache = false

    [run.model]
    name = "qwen36-local"

    [server.sandbox.providers.docker]
    enabled = true
  '';
in
{
  # Dedicated service identity shared by the Fabro server (Task 4) and the
  # nightly batch (Task 5, which drops to this user for `fabro` subcommands).
  users.users.fabro = {
    isSystemUser = true;
    group = "fabro";
    home = "/var/lib/fabro";
    # Fabro's docker sandbox provider talks to the Docker API socket, which on
    # this host is podman's (/run/docker.sock -> /run/podman/podman.sock, mode
    # 0660 group podman). The fabro worker runs as this user, so it must be in
    # the podman group to reach the socket — otherwise sandbox creation fails
    # with permission denied.
    extraGroups = [ "podman" ];
  };
  users.groups.fabro = { };

  # WARNING: night_llm_repos, night_llm_github_token, fabro_dev_token, and
  # fabro_session_secret MUST exist in secrets/secrets.yaml (added via `sops`)
  # BEFORE `nixos-rebuild switch`, otherwise sops-install-secrets fails the WHOLE
  # host activation — taking down the runner + dockerhub secrets in the same
  # file, not just Fabro.
  # Formats (Fabro-validated): fabro_dev_token = "fabro_dev_<64 hex>";
  # fabro_session_secret = 64 hex chars (>= 32 bytes).
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
  sops.secrets.fabro_session_secret = {
    owner = "fabro";
    group = "fabro";
    mode = "0400";
  };

  # Fabro reads its auth secrets from the environment (not settings.toml). Render
  # a systemd EnvironmentFile from the sops secrets so the plaintext never lands
  # in the Nix store.
  # SECURITY TRADEOFF: the fabro worker refuses to start without a GitHub token
  # ("GITHUB_TOKEN not configured — run fabro install or set GITHUB_TOKEN"), so
  # runs (incl. the nightly review) cannot execute without one. This reverses
  # the night-llm.nix intent of never handing the agent a token; the mitigation
  # is that review runs use a network-blocked sandbox (run.environment.network
  # .mode = "block"), so the agent cannot reach github.com to use it. We reuse
  # the read-only night_llm_github_token; keep that token's scope minimal.
  sops.templates."fabro-server.env" = {
    content = ''
      SESSION_SECRET=${config.sops.placeholder.fabro_session_secret}
      FABRO_DEV_TOKEN=${config.sops.placeholder.fabro_dev_token}
      GITHUB_TOKEN=${config.sops.placeholder.night_llm_github_token}
    '';
    owner = "fabro";
    group = "fabro";
    mode = "0400";
  };

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
      # OPENAI_API_KEY is a DUMMY: the openai provider is repointed at ollama
      # (see settings.toml) which ignores the key, but fabro's provider gate
      # needs *some* key present for a built-in provider to count as configured.
      Environment = [
        "HOME=/var/lib/fabro"
        "OPENAI_API_KEY=ollama-local-dummy"
      ];
      # SESSION_SECRET + FABRO_DEV_TOKEN (Fabro requires both when auth is on).
      EnvironmentFile = config.sops.templates."fabro-server.env".path;
      # Place settings.toml in the fabro-owned StateDirectory so Fabro's derived
      # config dir (/var/lib/fabro) is writable for environments/, etc.
      ExecStartPre = "${pkgs.coreutils}/bin/install -Dm644 ${settingsToml} /var/lib/fabro/settings.toml";
      # bind + web url come from settings.toml (single authority); only pass
      # what settings.toml can't express.
      # --foreground: without it `fabro server start` daemonizes and the
      # launcher exits, so systemd (Type=simple) tears down the forked server.
      ExecStart = "${fabroLib.fabroExe} server start --foreground --web --storage-dir /var/lib/fabro/storage --config /var/lib/fabro/settings.toml";
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
