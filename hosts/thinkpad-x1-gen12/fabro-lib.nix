{ self, lib }:
{
  # Single source of truth for the model tag + fabro binary, imported by both
  # fabro.nix and night-llm.nix so upgrades touch one place.
  # TODO(host follow-up): pin the model tag with a `@sha256:` digest once
  # resolved via `ollama` on the host — floating tags can drift silently.
  modelTag = "hf.co/HauhauCS/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive:Q4_K_M";
  fabroExe = lib.getExe self.packages.x86_64-linux.fabro;
}
