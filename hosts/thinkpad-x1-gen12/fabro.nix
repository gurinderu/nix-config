{ config, ... }:
{
  # Dedicated service identity shared by the Fabro server (Task 4) and the
  # nightly batch (Task 5, which drops to this user for `fabro` subcommands).
  users.users.fabro = {
    isSystemUser = true;
    group = "fabro";
    home = "/var/lib/fabro";
    createHome = true;
  };
  users.groups.fabro = { };

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
}
