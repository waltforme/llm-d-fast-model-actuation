#!/usr/bin/env bash

inst=$(date +%d-%H-%M-%S)
server_img=$(make echo-var VAR=TEST_SERVER_IMG)
requester_img=$(make echo-var VAR=TEST_REQUESTER_IMG)
if out=$(kubectl apply -f - 2>&1 <<EOF
apiVersion: fma.llm-d.ai/v1alpha1
kind: InferenceServerConfig
metadata:
  name: inference-server-config-$inst
spec:
  modelServerConfig:
    options: "--model meta-llama/Llama-2-7b-hf --tensor-parallel-size 1"
    env_vars:
      VLLM_SERVER_DEV_MODE: "1"
    labels:
      component: inference
    annotations:
      description: "Example InferenceServerConfig"
  launcherConfigName: launcher-config-$inst
---
apiVersion: fma.llm-d.ai/v1alpha1
kind: LauncherConfig
metadata:
  name: launcher-config-$inst
spec:
  maxSleepingInstances: 3
  podTemplate:
    spec:
      containers:
        - name: inference-server
          image: $server_img
          command:
          - /ko-app/test-server
          - --startup-delay=22
          resources:
            limits:
              cpu: "200m"
              memory: 9Gi
          readinessProbe:
            httpGet:
              path: /health
              port: 8000
            initialDelaySeconds: 10
            periodSeconds: 5
---
apiVersion: apps/v1
kind: ReplicaSet
metadata:
  name: my-request-$inst
  labels:
    app: dp-example
spec:
  replicas: 1
  selector:
    matchLabels:
      app: dp-example
  template:
    metadata:
      labels:
        app: dp-example
        instance: "$inst"
      annotations:
        dual-pods.llm-d.ai/admin-port: "8081"
        dual-pods.llm-d.ai/launcher-config: "launcher-config-$inst"
    spec:
      containers:
        - name: inference-server
          image: $requester_img
          imagePullPolicy: IfNotPresent
          command:
          - /ko-app/test-requester
          - --node=\$(NODE_NAME)
          - --pod-uid=\$(POD_UID)
          - --namespace=\$(NAMESPACE)
          env:
            - name: NODE_NAME
              valueFrom:
                fieldRef: { fieldPath: spec.nodeName }
            - name: POD_UID
              valueFrom:
                fieldRef: { fieldPath: metadata.uid }
            - name: NAMESPACE
              valueFrom:
                fieldRef: { fieldPath: metadata.namespace }
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
      serviceAccount: testreq
EOF
        )
then
    echo inference-server-config-$inst
    echo launcher-config-$inst
    echo my-request-$inst
else
    echo Failed to create objects >&2
    echo "$out" >&2
    exit 1
fi
