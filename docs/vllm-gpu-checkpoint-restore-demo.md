# Demo: FMA fast model switching via GPU checkpoint/restore

This playbook walks through a demonstration in which FMA drives fast model
switching using **CUDA GPU checkpoint/restore** instead of vLLM **sleep mode**.

Today FMA's dual-pods controller drives sleep mode by calling three HTTP
endpoints on each launcher-hosted vLLM instance. On this demo branch
(`adopt-vllm-gpucr`) those calls are surgically swapped for the customized
vLLM's GPU checkpoint/restore endpoints:

| Purpose         | Sleep mode (upstream) | Checkpoint/restore (this branch) |
|-----------------|-----------------------|----------------------------------|
| Free the GPU    | `POST /sleep`         | `POST /suspend`                  |
| Reclaim the GPU | `POST /wake_up`       | `POST /resume`                   |
| Query state     | `GET /is_sleeping`    | `GET /is_suspended`              |

The controller change is a hard swap (see `pkg/controller/dual-pods/inference-server.go`
and `pkg/api/interface.go`): the resulting controller build speaks
checkpoint/restore only. It is a branch-specific, demo-only build — not something
to merge to `main`.

## Scope

This demo covers **launcher-based** server-providing Pods only. Direct
server-providing Pods are out of scope.

## What the demo shows

1. **Cold start** — creating a server-requesting Pod makes FMA create a launcher
   and a launcher-hosted vLLM instance. The instance is awake; the GPU is in use.
2. **Suspend** — deleting the server-requesting Pod makes FMA call `/suspend`,
   which checkpoints the vLLM process and releases the GPU.
3. **Hot start** — re-creating the server-requesting Pod makes FMA call `/resume`,
   restoring the checkpointed instance and reclaiming the GPU.

At each step we check `GET /is_suspended` and `nvidia-smi`.

---

## Prerequisites

- A VM/node with a **single NVIDIA L4 GPU (24 GiB VRAM)**, reachable as a
  single-node Kubernetes cluster you are authorized to use.
- The node is labeled `nvidia.com/gpu.present=true` and advertises
  `nvidia.com/gpu` capacity (typically via the NVIDIA GPU Operator / device
  plugin).
- `kubectl`, `helm`, and — only for building the controller image —
  [`ko`](https://ko.build/) and a local Go toolchain.
- Push access to `quay.io/junatibm/fma` (or your own registry, if you rebuild
  every image).

### Container images

| Image                | Reference                                          | Origin |
|----------------------|----------------------------------------------------|--------|
| Customized vLLM      | `quay.io/junatibm/vllm:try-cuda-checkpoint`        | Built from the in-flight vLLM checkpoint/restore PRs; baked into the launcher image below. |
| Customized launcher  | `quay.io/junatibm/fma/launcher:adopt-vllm-gpucr`   | Already published. Its hosted vLLM instances expose `/suspend`, `/resume`, `/is_suspended`. |
| Modified controller  | `quay.io/junatibm/fma/dual-pods-controller:adopt-vllm-gpucr` | Built in Step 0 below, from this branch. |
| Requester            | `quay.io/junatibm/fma/requester:<tag>`             | The standard FMA requester (unchanged). Reuse an existing tag or build one. |

The **launcher-populator is not needed** for this demo: the dual-pods
controller creates the launcher Pod reactively when the server-requesting Pod
appears. We deploy with the populator disabled, which also avoids depending on a
populator image at the `adopt-vllm-gpucr` tag.

---

## Convenience variables

```shell
export CONTAINER_IMG_REG=quay.io/junatibm/fma
export IMAGE_TAG=adopt-vllm-gpucr
export LAUNCHER_IMAGE=${CONTAINER_IMG_REG}/launcher:${IMAGE_TAG}
export REQUESTER_IMAGE=${CONTAINER_IMG_REG}/requester:${IMAGE_TAG}
export NS=default                                              # namespace for the demo
export MODEL=Qwen/Qwen2.5-0.5B-Instruct                        # small enough for a 24 GiB L4
export VLLM_PORT=8000                                          # the vLLM instance port (ISC port)
```

---

## Step 0 — Build and push the modified controller image

From the root of this repository, on the `adopt-vllm-gpucr` branch:

```shell
make build-controller CONTAINER_IMG_REG=${CONTAINER_IMG_REG} IMAGE_TAG=${IMAGE_TAG}
```

This publishes `quay.io/junatibm/fma/dual-pods-controller:adopt-vllm-gpucr`
(`ko build` builds and pushes). Verify the tag exists in the registry before
continuing.

Build and push the requester image. Note the requester target reads its tag from
`REQUESTER_IMG_TAG` (default `latest`), **not** `IMAGE_TAG` — passing `IMAGE_TAG`
here has no effect and would build `requester:latest`:

```shell
make build-requester CONTAINER_IMG_REG=${CONTAINER_IMG_REG} REQUESTER_IMG_TAG=${IMAGE_TAG}
make push-requester  CONTAINER_IMG_REG=${CONTAINER_IMG_REG} REQUESTER_IMG_TAG=${IMAGE_TAG}
```

---

## Step 1 — Cluster preparation

Install the FMA CRDs (the install script in Step 2 can also do this via
`--install-crds true`, shown below):

```shell
kubectl apply --server-side -f config/crds.yaml
```

Optionally install the ValidatingAdmissionPolicy objects (not required for
correct functioning):

```shell
kubectl apply -f config/validating-admission-policies.yaml
```

Install the NVIDIA GPU Operator if not present.
```shell
helm install --wait --generate-name \
    -n gpu-operator --create-namespace \
    nvidia/gpu-operator \
    --version=v26.3.3 \
    --set cdi.enabled=false
```

---

## Step 2 — Deploy the modified FMA controllers

Deploy the chart with the modified controller image, the launcher-populator
**disabled**, coverage-data collection **disabled**, and a pullable image
policy for the controller.

> **Disable coverage on a demo VM.** By default the chart mounts a
> PersistentVolumeClaim for Go coverage data (`GOCOVERDIR`) and deploys a
> coverdata inspector. A single-node demo VM usually has no StorageClass, so
> that PVC stays `Pending` and the controller Pod never schedules. Setting
> `dualPodsController.coverage.enabled=false` drops the PVC, the mount, and the
> inspector. (The controller binary is `-cover`-instrumented but runs normally
> without `GOCOVERDIR`; it just emits no coverage.)

> **Set `global.local=false`.** `install-fma.sh`'s non-release path forces
> `global.local=true`, which sets the controller's `imagePullPolicy` to `Never`
> — correct for a `kind` cluster with side-loaded images, wrong for a demo that
> pulls the controller from quay.io (the Pod would fail `ErrImageNeverPull`).
> Override it with `--chart-set global.local=false` so the policy becomes
> `Always`. (`install-fma.sh` appends `--chart-set` values after its own
> `--set`, and the later value wins.) The launcher and requester Pods set their
> own `imagePullPolicy: Always` in later steps, so only the controller is
> affected.

```shell
scripts/install-fma.sh \
  --image-tag "${IMAGE_TAG}" \
  --oci-registry "${CONTAINER_IMG_REG}" \
  --enable-launcher-populator false \
  --install-crds false \
  --install-admission-policies false \
  --ensure-node-view-cluster-role node-viewer \
  --chart-set global.local=false \
  --chart-set dualPodsController.sleeperLimit=1 \
  --chart-set dualPodsController.coverage.enabled=false
```

What each option does:

- `--image-tag` / `--oci-registry` — **required**; select the demo images and
  the local chart.
- `--install-crds false` — the CRDs were already installed in Step 1, so the
  script does not re-apply them. (Pass `true` to install them here instead, and
  then drop the CRD step in Step 1.)
- `--install-admission-policies false` — the ValidatingAdmissionPolicy objects
  are **not required** for the demo. Pass `true` if you want them.
- `--enable-launcher-populator false` — the demo does not use the populator; the
  dual-pods controller creates launchers reactively.
- `--ensure-node-view-cluster-role node-viewer` — **required**; the controller
  runs a Node informer, so it needs a ClusterRole granting `get`/`list`/`watch`
  on Nodes. This creates/updates one named `node-viewer` and binds it.
- `--chart-set global.local=false` — pull the controller image (see the note
  above).
- `--chart-set dualPodsController.sleeperLimit=1` — allow at most one suspended
  server per GPU.
- `--chart-set dualPodsController.coverage.enabled=false` — disable the coverage
  PVC (see the note above).

Confirm the dual-pods controller is running, using the demo image, and set to
pull it:

```shell
kubectl -n "${NS}" get deploy -l app.kubernetes.io/name=fma-controllers
kubectl -n "${NS}" get deploy fma-dual-pods-controller \
  -o jsonpath='{.spec.template.spec.containers[0].image}{"\t"}{.spec.template.spec.containers[0].imagePullPolicy}{"\n"}'
# => quay.io/junatibm/fma/dual-pods-controller:adopt-vllm-gpucr   Always
```

---

## Step 3 — Create the InferenceServerConfig and LauncherConfig

There is **exactly one** `InferenceServerConfig` and **exactly one**
`LauncherConfig` throughout the demo. The LauncherConfig references the
customized launcher image; the launcher's hosted vLLM instances therefore expose
the checkpoint/restore endpoints.

The launcher Pod needs permission to patch its own Pod state, so we also create a
ServiceAccount + Role + RoleBinding for it.

```shell
kubectl apply -n "${NS}" -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gpucr-launcher
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: gpucr-launcher-pod-state-writer
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: gpucr-launcher-pod-state-writer
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: gpucr-launcher-pod-state-writer
subjects:
- kind: ServiceAccount
  name: gpucr-launcher
---
apiVersion: fma.llm-d.ai/v1alpha1
kind: InferenceServerConfig
metadata:
  name: gpucr-isc
spec:
  modelServerConfig:
    port: ${VLLM_PORT}
    options: >-
      --model ${MODEL}
      --gpu-memory-utilization 0.85
    env_vars:
      VLLM_SERVER_DEV_MODE: "1"
      VLLM_LOGGING_LEVEL: "DEBUG"
  launcherConfigName: gpucr-lc
---
apiVersion: fma.llm-d.ai/v1alpha1
kind: LauncherConfig
metadata:
  name: gpucr-lc
spec:
  maxInstances: 1
  podTemplate:
    spec:
      serviceAccountName: gpucr-launcher
      containers:
        - name: inference-server
          image: ${LAUNCHER_IMAGE}
          imagePullPolicy: Always
          command:
          - /app/launcher.py
          - --host=0.0.0.0
          - --log-level=info
          - --port=8001
          env:
          - name: HF_HOME
            value: "/tmp"
          - name: VLLM_CACHE_ROOT
            value: "/tmp"
          - name: FLASHINFER_WORKSPACE_BASE
            value: "/tmp"
          - name: TRITON_CACHE_DIR
            value: "/tmp"
          - name: XDG_CACHE_HOME
            value: "/tmp"
          - name: XDG_CONFIG_HOME
            value: "/tmp"
          resources:
            limits:
              ephemeral-storage: "8Gi"
EOF
```

> **Note on `--enable-sleep-mode`.** GPU checkpoint/restore does not rely on
> vLLM's sleep mode, so `--enable-sleep-mode` is intentionally omitted from the
> ISC options above. If your customized vLLM build still expects that flag,
> add it back to `modelServerConfig.options`.

---

## Step 4 — Cold start

Create the server-requesting Pod. We use a single-replica ReplicaSet so we can
delete and re-create the requester Pod by scaling it. The requester's annotation
binds it to the single ISC.

```shell
kubectl apply -n "${NS}" -f - <<EOF
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: gpucr-request
  labels:
    app: gpucr-example
spec:
  replicas: 1
  selector:
    matchLabels:
      app: gpucr-example
  template:
    metadata:
      labels:
        app: gpucr-example
      annotations:
        dual-pods.llm-d.ai/admin-port: "8081"
        dual-pods.llm-d.ai/inference-server-config: "gpucr-isc"
    spec:
      containers:
        - name: inference-server
          image: ${REQUESTER_IMAGE}
          imagePullPolicy: Always
          ports:
          - name: probes
            containerPort: 8080
          - name: spi
            containerPort: 8081
          readinessProbe:
            httpGet:
              path: /ready
              port: 8080
            initialDelaySeconds: 2
            periodSeconds: 5
          resources:
            limits:
              nvidia.com/gpu: "1"
              cpu: "200m"
              memory: 250Mi
EOF
```

In response, FMA creates a launcher Pod and a launcher-hosted vLLM instance.
This is the **cold start**. Watch the Pods. The `SUSPENDED` column is the
`dual-pods.llm-d.ai/sleeping` label, renamed for display via `custom-columns`
(`-L` would label the column `SLEEPING`, after the label key, and cannot rename
it):

```shell
kubectl -n "${NS}" get pods -w \
  -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,DUAL:.metadata.labels.dual-pods\.llm-d\.ai/dual,SUSPENDED:.metadata.labels.dual-pods\.llm-d\.ai/sleeping'
```

Wait for the server-requesting Pod to become READY (readiness is relayed from
the launcher once the instance is serving):

```shell
kubectl -n "${NS}" wait --for=condition=Ready pod -l app=gpucr-example --timeout=600s
```

Capture the launcher Pod name for the checks below:

```shell
export LAUNCHER_POD=$(kubectl -n "${NS}" get pods \
  -l dual-pods.llm-d.ai/launcher-config-name=gpucr-lc \
  -o jsonpath='{.items[0].metadata.name}')
echo "launcher pod: ${LAUNCHER_POD}"
```

**Checkpoint the state (expect: awake, GPU in use).**

```shell
# Send an inference request with temperature 0.
kubectl -n "${NS}" exec "${LAUNCHER_POD}" -c inference-server -- \
  curl -s localhost:${VLLM_PORT}/v1/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"The capital of France is\",\"max_tokens\":16,\"temperature\":0}" \
  | jq

# Suspend state should be false.
kubectl -n "${NS}" exec "${LAUNCHER_POD}" -c inference-server -- \
  curl -s localhost:${VLLM_PORT}/is_suspended
# => {"is_suspended":false}

# nvidia-smi should show the vLLM process holding GPU memory.
nvidia-smi
```

---

## Step 5 — Suspend (delete the server-requesting Pod)

Delete the server-requesting Pod by scaling the ReplicaSet to zero. In response,
FMA calls `/suspend` on the launcher-hosted vLLM instance, which checkpoints it
and releases the GPU. The launcher Pod and the (now suspended) instance remain.

```shell
kubectl -n "${NS}" scale rs/gpucr-request --replicas=0
```

Give the checkpoint a few seconds, then check (expect: suspended, GPU released).

```shell
# Suspend state should now be true.
kubectl -n "${NS}" exec "${LAUNCHER_POD}" -c inference-server -- \
  curl -s localhost:${VLLM_PORT}/is_suspended
# => {"is_suspended":true}

# nvidia-smi should show the GPU memory released (no vLLM process).
nvidia-smi

# The controller also reflects this on the launcher Pod's label
# (SUSPENDED column = the dual-pods.llm-d.ai/sleeping label).
kubectl -n "${NS}" get pod "${LAUNCHER_POD}" \
  -o custom-columns='NAME:.metadata.name,SUSPENDED:.metadata.labels.dual-pods\.llm-d\.ai/sleeping'
```

---

## Step 6 — Hot start (re-create the server-requesting Pod)

Re-create the server-requesting Pod (referring to the same ISC) by scaling the
ReplicaSet back to one. In response, FMA calls `/resume` to restore the
checkpointed instance and reclaim the GPU. This is the **hot start**.

```shell
kubectl -n "${NS}" scale rs/gpucr-request --replicas=1
kubectl -n "${NS}" wait --for=condition=Ready pod -l app=gpucr-example --timeout=600s
```

The launcher Pod is the same one; refresh the variable in case you opened a new
shell:

```shell
export LAUNCHER_POD=$(kubectl -n "${NS}" get pods \
  -l dual-pods.llm-d.ai/launcher-config-name=gpucr-lc \
  -o jsonpath='{.items[0].metadata.name}')
```

**Checkpoint the state (expect: awake again, GPU in use).**

```shell
kubectl -n "${NS}" exec "${LAUNCHER_POD}" -c inference-server -- \
  curl -s localhost:${VLLM_PORT}/v1/completions \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"prompt\":\"The capital of France is\",\"max_tokens\":16,\"temperature\":0}" \
  | jq

kubectl -n "${NS}" exec "${LAUNCHER_POD}" -c inference-server -- \
  curl -s localhost:${VLLM_PORT}/is_suspended
# => {"is_suspended":false}

nvidia-smi
```

Because the response was produced with `temperature 0`, the completion text
should match the one from the cold start, showing that restore returned the
instance to a working state.

---

## Expected observations

| Step        | Trigger                       | FMA call   | `/is_suspended` | `nvidia-smi` (vLLM memory) |
|-------------|-------------------------------|------------|-----------------|----------------------------|
| Cold start  | Create requester Pod          | (create)   | `false`         | in use                     |
| Suspend     | Delete requester Pod (scale 0)| `/suspend` | `true`          | released                   |
| Hot start   | Re-create requester (scale 1) | `/resume`  | `false`         | in use                     |

---

## Cleanup

```shell
kubectl -n "${NS}" delete rs/gpucr-request
kubectl -n "${NS}" delete pod ${LAUNCHER_POD}
kubectl -n "${NS}" delete inferenceserverconfig/gpucr-isc launcherconfig/gpucr-lc
kubectl -n "${NS}" delete rolebinding/gpucr-launcher-pod-state-writer \
  role/gpucr-launcher-pod-state-writer sa/gpucr-launcher
helm uninstall fma
```

---

## Troubleshooting

- **Controller not calling the checkpoint endpoints.** Confirm the running
  dual-pods controller image is
  `quay.io/junatibm/fma/dual-pods-controller:adopt-vllm-gpucr` (Step 2). The
  stock image speaks `/sleep`, `/wake_up`, `/is_sleeping`.
- **Launcher Pod never appears.** The dual-pods controller creates it reactively
  from the requester Pod. Check controller logs and that the requester's
  `dual-pods.llm-d.ai/inference-server-config` annotation names the ISC.
- **`nvidia-smi` still shows memory after suspend.** Give the checkpoint a few
  more seconds and re-check `/is_suspended`; the label
  `dual-pods.llm-d.ai/sleeping=true` on the launcher Pod (the `SUSPENDED` column
  above) confirms the controller believes the instance is suspended.
- **Model does not fit on the L4.** Use a smaller model or lower
  `--gpu-memory-utilization` in the ISC options.
