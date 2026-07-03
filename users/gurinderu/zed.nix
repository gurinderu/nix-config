{
  pkgs,
  pkgs-unstable,
  config,
  ...
}:
{

  home.activation.zedGithubToken = config.lib.dag.entryAfter [ "writeBoundary" ] ''
    CONFIG="$HOME/Library/Application Support/Zed/settings.json"
    if [ -f "$CONFIG" ]; then
      $DRY_RUN_CMD sed -i \
        "s|GITHUB_TOKEN|$(cat ${config.sops.secrets.github_token_read.path})|g" \
        "$CONFIG"
    fi
  '';

  programs.zed-editor = {
    package = pkgs-unstable.zed-editor;
    enable = true;
    extensions = [
      "docker-compose"
      "git-firefly"
      "html"
      "nix"
      "nu"
      "toml"
      "terraform"
      "dockerfile"
      "sql"
      "make"
      "xml"
      "log"
      "graphql"
      "mcp-server-context7"
      "mcp-server-github"
      "mcp-server-slack"
      "mcp-server-grafana"
      "xcode-themes"
      "fleet-themes"
      "basher"
      "markdown-oxide"
      "proto"
      "env"
      "just"
      "nginx"
      "typst"
      "helm"
      "slint"
      "autocorrect"
      "perplexity"
      "strace"
      "crates-lsp"
      "leptos"
      "catppuccin"
    ];
    extraPackages = with pkgs; [
      nixd
      nil
      rustfmt
      rust-analyzer
    ];
    userSettings = {
      # appearance
      theme = {
        mode = "system";
        light = "Catppuccin Latte";
        dark = "Catppuccin Mocha";
      };
      ui_font_size = 14;
      buffer_font_size = 14;
      buffer_font_family = ".ZedMono";
      buffer_line_height = "comfortable";

      # editor
      base_keymap = "JetBrains";
      autosave = "on_focus_change";
      auto_update = false;
      format_on_save = "on";
      soft_wrap = "editor_width";
      tab_size = 2;
      show_whitespaces = "selection";
      relative_line_numbers = false;

      # indent guides
      indent_guides = {
        enabled = true;
        coloring = "indent_aware";
      };

      # tabs
      tabs = {
        file_icons = true;
        git_status = true;
        show_diagnostics = "errors";
      };
      tab_bar = {
        show_nav_history_buttons = false;
      };

      # panels
      project_panel = {
        dock = "left";
        git_status = true;
        indent_size = 16;
      };
      outline_panel = {
        dock = "right";
      };
      git_panel = {
        dock = "right";
      };
      notification_panel = {
        dock = "right";
      };
      chat_panel = {
        dock = "right";
      };

      # toolbar
      toolbar = {
        breadcrumbs = true;
        quick_actions = true;
      };

      # scrollbar
      scrollbar = {
        show = "auto";
        cursors = true;
        git_diff = true;
        search_results = true;
        diagnostics = "all";
      };

      # git
      git = {
        enabled = true;
        autoFetch = true;
        autoFetchInterval = 300;
        inline_blame = {
          enabled = true;
          delay_ms = 500;
        };
      };

      # terminal
      terminal = {
        font_size = 13;
        blinking = "terminal_controlled";
        copy_on_select = true;
        dock = "bottom";
      };

      # direnv integration
      load_direnv = "shell_hook";

      # ai assistant
      assistant = {
        default_model = {
          provider = "zed.dev";
          model = "claude-sonnet-4-6";
        };
        version = "2";
      };

      # lsp
      lsp = {
        rust-analyzer = {
          binary = {
            path_lookup = true;
          };
          initialization_options = {
            check = {
              command = "clippy";
            };
            inlayHints = {
              enabled = true;
              typeHints.enabled = true;
              parameterHints.enabled = true;
              chainingHints.enabled = true;
            };
          };
        };
        nix = {
          binary = {
            path_lookup = true;
          };
        };
        nixd = {
          binary = {
            path_lookup = true;
          };
        };
      };

      # language specific
      languages = {
        Rust = {
          tab_size = 4;
          format_on_save = "on";
          code_actions_on_format = {
            "source.fixAll" = true;
          };
        };
        Nix = {
          tab_size = 2;
          format_on_save = "on";
        };
        TypeScript = {
          tab_size = 2;
          format_on_save = "on";
        };
        JSON = {
          tab_size = 2;
        };
        YAML = {
          tab_size = 2;
        };
      };
      nixcontext_servers = {
        "mcp-server-context7" = {
          settings = { };
        };
        "mcp-server-github" = {
          settings = {
            github_personal_access_token = "GITHUB_TOKEN";
          };
        };
      };
    };
  };
}
