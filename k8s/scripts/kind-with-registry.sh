#!/bin/bash
set -o errexit

REGISTRY_NAME="kind-registry"
REGISTRY_PORT="5001"
CLUSTER_NAME="microservices-local"
KIND_VERSION="v1.32.0"  # pin to a recent stable version

# 1. Start the local registry if not already running
if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run \
    -d --restart=always \
    -p "127.0.0.1:${REGISTRY_PORT}:5000" \
    --network bridge \
    --name "${REGISTRY_NAME}" \
    registry:2
fi

# 2. Create the kind cluster (if it doesn't exist) with registry config
if ! kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --image "kindest/node:${KIND_VERSION}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
  - role: worker
  - role: worker
containerdConfigPatches:
  - |-
    [plugins."io.containerd.grpc.v1.cri".registry]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REGISTRY_PORT}"]
          endpoint = ["http://${REGISTRY_NAME}:5000"]
EOF
fi

# 3. Connect the registry to the kind network (idempotent)
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REGISTRY_NAME}"
fi

# 4. Document the local registry in the cluster (used by tools like Tilt, Skaffold)
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo ""
echo "Cluster '${CLUSTER_NAME}' is ready."
echo "Registry available at: localhost:${REGISTRY_PORT}"
echo "Push images as: localhost:${REGISTRY_PORT}/<image>:<tag>"
