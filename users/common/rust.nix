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
      # Darwin only (in practice: the fanless M2 Air, the only darwin host —
      # if a second one ever appears, lift this into a host-supplied option
      # instead of inheriting an 8-core constant). Unbounded cargo, often
      # several concurrent sessions of it, is what drove the 2026-07-30 and
      # 2026-09-02..05 load storms — e.g. five concurrent ~1GB `ld` processes
      # swapping the machine out — and every packet on this host crosses the
      # userspace sing-box daemon, so a build storm IS a network outage
      # (>50% tunnel-probe failures at load1 >= 64, zero the one night
      # without builds).
      #
      # Be honest about the bound this buys: `jobs` is PER INVOCATION, so
      # three concurrent sessions still reach 12 — it halves each session's
      # contribution, nothing more. It also sets concurrency, not QoS or
      # core affinity (macOS schedules by QoS class, so these still land on
      # P-cores). And nix-built Rust (meridian, net-observerd) never reads
      # this file at all — the cargo hook passes -j $NIX_BUILD_CORES, bounded
      # by nix.settings.cores in hosts/mac_aarch64/configuration.nix, which
      # also carries the QoS half (nix.daemonProcessType = "Background").
      # A machine-wide aggregate cap would need a wrapper/semaphore outside
      # cargo; not worth it until the per-session cap proves insufficient.
      jobs = 4
    '';
}
