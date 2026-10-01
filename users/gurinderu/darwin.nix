{ pkgs, ... }:
{
  home.packages = with pkgs; [
    colima
    docker-credential-helpers
  ];

  # Default buildx builder = "apple": a moby/buildkit container running inside
  # Apple container (see hosts/mac_aarch64/socktainer.nix, which heals the
  # builder's buildx instance file). socktainer's own docker-container driver
  # path is flakier (a restarted buildkit node starts failing with "operation
  # not permitted" and must be recreated), so builds go to the dedicated
  # buildkitd socket instead. Env beats `docker buildx use`, so this holds
  # regardless of imperative buildx state; one-off escape hatch:
  # `BUILDX_BUILDER=socktainer docker build …` (or unset for `docker buildx
  # use` semantics).
  home.sessionVariables.BUILDX_BUILDER = "apple";

  # macOS terminals set LC_CTYPE=UTF-8, and ssh forwards it (SendEnv LC_*).
  # That name is macOS-only: Linux has no such locale, so remote shells fall
  # back to ASCII and mosh-server refuses to start. A full locale name means
  # the same thing here and is valid on both.
  home.sessionVariables.LC_CTYPE = "en_US.UTF-8";
}
