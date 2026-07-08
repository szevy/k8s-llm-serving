# Serving a Small LLM on Kubernetes

A hands-on project demonstrating the Kubernetes serving pattern for a large language model, using a tiny quantised model that runs on CPU (no GPU required). Runs locally on minikube.

## Honest scope

This serves a genuinely small LLM (Qwen2.5-0.5B, 4-bit GGUF) via llama.cpp's OpenAI-compatible server, deployed on Kubernetes with a Deployment, Service, health probes, and an HPA. The point is to demonstrate the serving pattern (containerise, deploy, probe, load-balance, autoscale), not production-scale LLM serving. The same manifests scale to GPU nodes for large models; production would add GPU scheduling, multi-node, and GPU-based autoscaling metrics.

## Prerequisites

- Docker, minikube, kubectl
- metrics-server for the HPA: `minikube addons enable metrics-server`

## Quick start

1. Start the cluster and enable metrics-server:
   ```bash
   minikube start
   minikube addons enable metrics-server
   ```

2. Build the image (downloads the ~350MB model at build time):
   ```bash
   docker build -t llm-service:latest .
   ```

3. Load the image into minikube (deployment uses imagePullPolicy: Never):
   ```bash
   minikube image load llm-service:latest
   ```

   Alternative (faster, avoids the copy): build the image directly inside minikube's Docker daemon, so there is nothing to load. Point your Docker client at minikube's daemon first, then build:
   ```bash
   eval $(minikube docker-env)
   docker build -t llm-service:latest .
   # no `minikube image load` needed; the image is already in the cluster
   ```
   To point Docker back at your host daemon afterwards: `eval $(minikube docker-env -u)`.

4. Deploy:
   ```bash
   kubectl apply -f k8s/
   kubectl get pods                 # wait for 1/1 Running (model load takes a bit)
   ```

5. Test (port-forward, then call the OpenAI-compatible API):
   ```bash
   kubectl port-forward service/llm-service 8000:8000
   # in another terminal:
   curl http://localhost:8000/health
   curl http://localhost:8000/v1/chat/completions \
     -H "Content-Type: application/json" \
     -d '{"messages":[{"role":"user","content":"Say hello in one sentence."}]}'
   ```

6. Clean up:
   ```bash
   minikube delete
   ```

## Verifying load balancing across the two instances

The Deployment runs 2 replicas and the Service load-balances across them. Note that `kubectl port-forward` pins to a single pod and bypasses the Service, so to see balancing you must call the Service by name from inside the cluster.

Stream each pod's logs in two terminals:
```bash
kubectl get pods                       # get the two pod names
kubectl logs -f <pod-1>                # terminal 1
kubectl logs -f <pod-2>                # terminal 2
```

Then fire requests through the Service (not port-forward) from a temporary in-cluster pod:
```bash
kubectl run curl-test --image=curlimages/curl -it --rm --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6; do curl -s http://llm-service:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":5}"; echo; done'
```

Both pods' logs show `launch_slot_ ... processing task` lines, confirming requests are distributed across both instances. The balancing is done by kube-proxy (default iptables mode, random selection), configured only by the Service's label selector. The logs also show llama.cpp reusing cached prompt prefixes (`selected slot by LCP similarity`) and serving at roughly 18-27 tokens/second on CPU.

## Notes

- CPU-only: minikube on a laptop has no GPU, so inference runs on CPU and is slow. This is expected; the model is tiny specifically so it works at all on CPU.
- Probes: llama.cpp's server exposes /health; the Deployment uses it for liveness and readiness. initialDelaySeconds is generous because the model must load before the server is ready.
- Autoscaling: the HPA scales on CPU (min 2, max 4, target 70%). On a real GPU cluster you would scale on a GPU-aware metric like queue depth instead, since CPU is not the bottleneck for LLM inference.
- The manifests are the transferable part: swap the image for a vLLM GPU image and add a GPU resource request, and the same Deployment/Service/HPA pattern serves a large model on GPU nodes.