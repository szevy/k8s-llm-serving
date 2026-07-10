# CPU-only LLM server using llama.cpp's built-in OpenAI-compatible server.
# Uses a tiny quantised GGUF model so it runs on a laptop CPU (no GPU needed).
FROM ghcr.io/ggml-org/llama.cpp:server

# Download a tiny instruct model at build time (~350MB, Qwen2.5-0.5B Q4_K_M).
# Adjust the URL/model if you prefer a different tiny GGUF.
ADD https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf /models/model.gguf

# llama.cpp server listens on 8000, exposes an OpenAI-compatible /v1 API
# plus a /health endpoint (used by the Kubernetes probes).
EXPOSE 8000
ENTRYPOINT ["/app/llama-server", "-m", "/models/model.gguf", "--host", "0.0.0.0", "--port", "8000", "-c", "2048", "--metrics"]
