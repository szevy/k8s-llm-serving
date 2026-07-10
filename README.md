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
   kubectl delete pod curl-test --ignore-not-found   # remove the in-cluster test pod if it lingered
   # Ctrl+C any running kubectl port-forward and kubectl logs -f terminals
   kubectl delete -f k8s/                            # remove the Deployment, Service, HPA (and Ingress if applied)
   minikube delete                                   # or tear down the whole cluster
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

## Smarter load balancing with an nginx ingress (EWMA)

The Service (above) balances via kube-proxy, which in default iptables mode uses random per-request selection. For a smarter algorithm, put an nginx ingress in front of the Service and select the load-balancing method with an annotation.

`k8s/ingress.yaml` uses EWMA (Peak EWMA), which routes more traffic to the backends replying fastest (least loaded). This suits variable-duration LLM requests better than blind round-robin or random, because it accounts for how long each backend is taking.

```bash
# enable the nginx ingress controller (one-time)
minikube addons enable ingress
kubectl get pods -n ingress-nginx        # wait for the controller pod to be Running

# apply the ingress
kubectl apply -f k8s/ingress.yaml
kubectl get ingress                      # wait until an ADDRESS appears
```

Test it. On the minikube Docker driver (e.g. WSL2), the ingress IP is not directly reachable from the host, so port-forward to the controller:

```bash
# terminal A (leave running)
kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8080:80

# terminal B: route by hostname (the ingress matches the Host header)
for i in 1 2 3 4 5 6; do
  curl -s -H "Host: llm-service.local" http://localhost:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
  echo
done
```

Traffic now flows client -> nginx ingress (EWMA) -> Service -> pods, instead of straight to the Service (kube-proxy random). With only two pods and a tiny model the visible difference is small; the point is that the load-balancing algorithm is configurable and EWMA is a better fit for variable-length LLM requests.

Note on terminology: this is the nginx INGRESS controller's EWMA, configured by annotation. It is a different layer from a standalone Nginx reverse proxy with a `least_conn` upstream; the ingress controller generates its own config from the Ingress resource.

## Monitoring with Prometheus and Grafana

Metrics flow: llama.cpp exposes a /metrics endpoint on each pod -> Prometheus scrapes and stores them as time series -> Grafana displays them as dashboards. Prometheus is the collector/database; Grafana is the screen.

### 1. Enable the metrics endpoint

llama.cpp's server has a Prometheus-compatible metrics endpoint, disabled by default. The Dockerfile ENTRYPOINT enables it with the `--metrics` flag:

```dockerfile
ENTRYPOINT ["/app/llama-server", "-m", "/models/model.gguf", "--host", "0.0.0.0", "--port", "8000", "-c", "2048", "--metrics"]
```

Rebuild and deploy (fresh cluster: apply; existing cluster: rollout restart):

```bash
docker build -t llm-service:latest .
minikube image load llm-service:latest
kubectl apply -f k8s/            # or: kubectl rollout restart deployment/llm-service
kubectl get pods                 # wait for both pods 1/1 Running
```

Verify the endpoint (port-forward pins to one pod; that is fine for this check):

```bash
kubectl port-forward service/llm-service 8000:8000
# in another terminal:
curl -s http://localhost:8000/metrics | head -15
# expect llamacpp:* counters in Prometheus text format (zeros until traffic arrives)
```

### 2. Install the monitoring stack (Helm)

Helm is the Kubernetes package manager; the kube-prometheus-stack chart installs Prometheus, Grafana, Alertmanager and their wiring in one command.

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm install monitoring prometheus-community/kube-prometheus-stack -n monitoring --create-namespace
kubectl get pods -n monitoring   # wait until all six pods are Running (a few minutes)
```

### 3. Tell Prometheus to scrape the llm pods (ServiceMonitor)

Prometheus does not scrape anything automatically; a ServiceMonitor object declares "scrape services matching these labels". Two prerequisites in `k8s/service.yaml`: the Service must carry a label the ServiceMonitor can select (`labels: app: llm-service` in its metadata), and the port must be named (`name: http`), because ServiceMonitors reference ports by name.

`k8s/servicemonitor.yaml`:

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: llm-service
  labels:
    release: monitoring        # required: the stack only picks up ServiceMonitors carrying its Helm release label
spec:
  selector:
    matchLabels:
      app: llm-service         # matches the labels on the Service object
  endpoints:
    - port: http               # the named port in service.yaml
      interval: 15s
      path: /metrics
```

Apply and verify:

```bash
kubectl apply -f k8s/service.yaml -f k8s/servicemonitor.yaml

# open the Prometheus UI:
kubectl port-forward -n monitoring svc/monitoring-kube-prometheus-prometheus 9090:9090
# browser: http://localhost:9090/targets -> the llm-service target should show 2 endpoints, state UP (~1 min)
```

### 4. Generate traffic and query the metrics

Send requests through the Service from inside the cluster (port-forward pins to one pod, so it does not exercise load balancing):

```bash
kubectl run curl-test --image=curlimages/curl -it --rm --restart=Never -- \
  sh -c 'for i in 1 2 3 4 5 6; do curl -s http://llm-service:8000/v1/chat/completions -H "Content-Type: application/json" -d "{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}" > /dev/null; echo done $i; done'
```

In the Prometheus UI (http://localhost:9090/graph), run:

```
llamacpp:tokens_predicted_total          # cumulative tokens per pod (one series per pod)
rate(llamacpp:tokens_predicted_total[5m])  # tokens/second over the last 5 minutes
```

Both pods' counters should be nonzero after in-cluster traffic. Traffic sent via port-forward lands on a single pod only, which is visible in the per-pod series: an observable demonstration of the port-forward pinning behaviour.

### 5. Grafana dashboard as code

Instead of building panels in the Grafana UI, the dashboard is defined as JSON in a ConfigMap (`k8s/dashboard.yaml`). The stack's sidecar watches for ConfigMaps labelled `grafana_dashboard: "1"` in the monitoring namespace and loads them automatically.

```bash
kubectl apply -f k8s/dashboard.yaml
# wait ~30-60s for the sidecar to load it
```

Open Grafana:

```bash
# admin password:
kubectl --namespace monitoring get secrets monitoring-grafana -o jsonpath="{.data.admin-password}" | base64 -d ; echo

# tunnel (if local port 3000 is taken, use 3001:80 and browse to localhost:3001):
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```

Browser: http://localhost:3000, login `admin` plus the password above, then Dashboards -> "LLM Serving". Four panels, one line per pod: generation rate (tokens/sec), total tokens generated, prompt tokens processed, decode calls/sec. Send traffic (step 4) and the panels update within one scrape interval.

### Port-forward reference

Multiple port-forwards run side by side in separate terminals; they do not conflict (different local ports). Stop any with Ctrl+C when done.

| Local port | Target | Purpose |
| --- | --- | --- |
| 8000 | service/llm-service 8000 | poke the LLM API / metrics endpoint (pins to ONE pod) |
| 9090 | monitoring-kube-prometheus-prometheus 9090 | Prometheus UI (targets, queries) |
| 3000 | monitoring-grafana 80 | Grafana UI (dashboards) |


## CI/CD (GitHub Actions)

`.github/workflows/ci.yaml` runs three jobs on pushes and pull requests to main:

**build-and-smoke-test**
1. Builds the Docker image (catches Dockerfile breakage, e.g. a wrong ENTRYPOINT path, in CI instead of at deploy time).
2. Smoke-tests the binary (`--help` must print).
3. Starts the server on the CI runner and polls /health until the model loads (the same startup-delay reasoning as the readiness probe), failing the build if it never becomes healthy.
4. Validates the core Kubernetes manifests with a client-side dry run. The ServiceMonitor and dashboard ConfigMap are excluded here because their custom resource definitions only exist in a cluster with the monitoring stack installed; they are exercised on the real cluster instead.

**deploy-test** (integration test)
Creates a throwaway kind cluster (Kubernetes in Docker) on the runner, loads the image, applies the core manifests, requires the rollout to become healthy, and verifies /health answers through the Service from inside the cluster. Proves the manifests deploy cleanly end to end on a real API server, not just parse.

**push-to-registry** (continuous delivery of the artifact)
On green commits to main only: builds and pushes the image to GitHub Container Registry (ghcr.io), tagged with the commit SHA and as latest. Every green commit produces a versioned, pullable artifact. Full CD to a persistent cluster would follow the GitOps pattern (ArgoCD/Flux watching the repo); there is no persistent cluster in this project, so delivery stops at the registry.

## Quantising the model from the FP16 original

Instead of downloading a pre-quantised GGUF, the model can be quantised from the original FP16 weights using llama.cpp's standard pipeline, run via their Docker tools image (no local llama.cpp build needed). `./quantise.sh` reproduces the whole process; the steps it runs:

1. **Download the FP16 original** (~943MB safetensors plus tokenizer/config, HuggingFace format):
   ```bash
   hf download Qwen/Qwen2.5-0.5B-Instruct --local-dir quantisation/qwen-fp16
   ```

2. **Convert HuggingFace format to GGUF** (format repackaging only; weights stay FP16, size stays ~949MB). GGUF is llama.cpp's single-file format bundling weights, architecture metadata, and tokenizer:
   ```bash
   docker run --rm -v "$(pwd)/quantisation:/models" ghcr.io/ggml-org/llama.cpp:full \
     --convert --outtype f16 --outfile /models/qwen-f16.gguf /models/qwen-fp16/
   ```

3. **Quantise to Q4_K_M** (the actual quantisation: FP16 weights become ~4-bit integers; 949MB to ~380MB):
   ```bash
   docker run --rm -v "$(pwd)/quantisation:/models" ghcr.io/ggml-org/llama.cpp:full \
     --quantize /models/qwen-f16.gguf /models/qwen-q4_k_m.gguf Q4_K_M
   ```

4. **Serve the artifact**: swap the Dockerfile's model line from the ADD-from-HuggingFace to copying the locally produced artifact, then the usual build/load/rollout serves it on the cluster:
   ```dockerfile
   # default (CI-compatible): download the published pre-quantised model
   ADD https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct-GGUF/resolve/main/qwen2.5-0.5b-instruct-q4_k_m.gguf /models/model.gguf
   # self-quantised variant (local builds): use the locally produced artifact instead
   # COPY quantisation/qwen-q4_k_m.gguf /models/model.gguf
   ```
   The committed Dockerfile keeps the ADD form because CI builds on a clean runner where the gitignored `quantisation/` artifact does not exist; the COPY form is the local variant after running `./quantise.sh`.

5. **Build, deploy, and verify on the cluster** (with the COPY line active locally):
   ```bash
   docker build -t llm-service:latest .
   minikube image load llm-service:latest
   kubectl rollout restart deployment/llm-service
   kubectl get pods                     # wait for the new generation's pods, 1/1 Running

   kubectl port-forward service/llm-service 8000:8000
   # in another terminal, send a chat request to the self-quantised model:
   curl -s http://localhost:8000/v1/chat/completions -H "Content-Type: application/json" \
     -d '{"messages":[{"role":"user","content":"Introduce yourself in one sentence."}],"max_tokens":40}'
   ```
   A coherent JSON completion confirms the end-to-end pipeline: FP16 download, format conversion, Q4_K_M quantisation, image build, rolling update, and serving, all with the self-quantised artifact.

Notes:
- **Q4_K_M decoded**: Q4 = ~4-bit precision class; K = llama.cpp's block-wise scheme with per-block scale factors; M = the medium variant, keeping critical layers at higher precision. Effective ~4.8 bits per weight (hence 380MB rather than 949/4), and the community's default quality/size trade-off.
- **Choosing a level**: Q4_K_M is the standard starting point; step up (Q5_K_M, Q8_0) if quality matters and memory allows, down (Q3_K_M) only when memory forces it. Quantisation loss is permanent, grows steeply below 4-bit, and hits small models proportionally harder than large ones.
- **Honest scope**: this is GGUF's standard calibration-free quantisation. Calibration-based methods (GPTQ/AWQ, used for vLLM-served models) additionally compensate quantisation error against sample data; that pipeline is not run here.
- The `quantisation/` directory is gitignored: model artifacts are reproducible outputs and do not belong in git. The repo carries the recipe (this script), not the binaries.