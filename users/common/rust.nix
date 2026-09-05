# Rust build tooling: sccache as the rustc wrapper, plus global cargo profile
# defaults that cut debug-info weight.
#
# Incremental compilation stays at cargo's default (on). sccache cannot cache
# incremental units, so workspace-local crates are not cached — that is an
# accepted trade for fast direct local iteration. Dependencies are always built
# non-incrementally and do hit the cache, including across projects. Anything
# that wants full sccache coverage (rig candidate runs) sets CARGO_INCREMENTAL=0
# for itself, once it has its own artifact namespace and resource limits.
#
# Caveat worth remembering: the cache key includes the compiler hash, so
# projects pinned to different toolchains in their rust-toolchain.toml share
# nothing with each other.
#
# Profiles set here apply on top of every project's Cargo.toml, so no
# repository needs modifying; a repo's own .cargo/config.toml still wins.
{ pkgs, lib, ... }:
{
  home.sessionVariables = {
    RUSTC_WRAPPER = "sccache";
    SCCACHE_CACHE_SIZE = "32G";
  };

  home.file.".cargo/config.toml".text =
    ''
      # Managed by home-manager (users/common/rust.nix) — edit it there.

      [profile.dev]
      # Incremental is intentionally NOT set here — see the note above.

      # Full DWARF across the whole dependency tree dominates both link time and
      # target/ size. Line tables still give backtraces with file:line, which is
      # what a debug build needs day to day.
      debug = "line-tables-only"

      [profile.dev.package."*"]
      # Third-party crates are effectively never stepped through in a debugger.
      debug = false
    ''
    + lib.optionalString pkgs.stdenv.isDarwin ''

      [build]
      # Darwin only: cap cargo's parallelism on the fanless M2 Air. Unbounded
      # cargo (often several concurrent sessions of it) is what drove the
      # 2026-07-30 and 2026-09-02..05 load storms — e.g. five concurrent ~1GB
      # `ld` processes swapping the machine out. Every packet on this host
      # crosses the userspace sing-box daemon, so a build storm IS a network
      # outage (>50% tunnel-probe failures at load1 >= 64, zero failures the
      # one night without builds). 4 = the P-core count; the E-cores stay
      # free for the interactive/network side.
      jobs = 4
    '';
}
