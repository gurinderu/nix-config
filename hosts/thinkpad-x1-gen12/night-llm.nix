{ ... }:
{
  # Local LLM serving for Fabro. CPU inference (Intel Arc iGPU is unsupported by
  # ollama accel); MoE 3B-active keeps it fast despite the 35B weight footprint.
  services.ollama = {
    enable = true;
    host = "127.0.0.1";
    port = 11434;
    environmentVariables = {
      OLLAMA_KEEP_ALIVE = "10m"; # unload the model 10 min after last use → frees ~21 GB
      OLLAMA_MAX_LOADED_MODELS = "1";
    };
  };
}
