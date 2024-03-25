{
  enable = true;
  settings = {
    format = "$all";
    add_newline = true;
    directory = {
      read_only = " ";
    };
    docker_context = {
      symbol = " ";
    };
    git_branch = {
      symbol = " ";
    };
    haskell = {
      symbol = " ";
    };
    nix_shell = {
      symbol = " ";
    };
    rust = {
      symbol = " ";
    };
    battery = {
      full_symbol = "🔋 ";
      charging_symbol = "⚡️ ";
      discharging_symbol = "💀 ";
      display = [{
        threshold = 10;
        style = "bold red";
      }];
    };

  };
}
