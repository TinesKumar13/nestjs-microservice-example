# NestJS Microservices on Local Kubernetes

A complete step-by-step guide to deploying a NestJS microservices application to a local Kubernetes cluster using production-grade practices: Helm, Kubernetes Gateway API, TLS termination, and Istio.

---

## Architecture

```
Client (HTTPS)
      │
      ▼
[Istio Envoy Gateway]  ← TLS terminated here (cert-manager, self-signed)
      │ HTTP
      ▼
[gateway-service]      ← ClusterIP, HTTP :3000, gRPC client
      │ gRPC
      ▼
[identity-service]     ← ClusterIP, gRPC :50051
      │
  ┌───┴────┐
  ▼        ▼
PostgreSQL  NATS JetStream
```

**Two application services:**
- `gateway-service` — HTTP REST entry point (port 3000), routes to identity-service via gRPC
- `identity-service` — gRPC server (port 50051), writes to PostgreSQL, publishes events via NATS

**Infrastructure:**
- PostgreSQL — user storage
- NATS JetStream — async event bus

---

## Prerequisites

Install all of the following before starting:

| Tool | Version | Notes |
|---|---|---|
| Docker Desktop | Latest | Enable WSL2 backend on Windows |
| kind | v0.20+ | Kubernetes-in-Docker |
| kubectl | v1.28+ | Comes with Docker Desktop or install separately |
| Helm | v3.x | Package manager for Kubernetes |
| istioctl | v1.20+ | Istio CLI |
| Git Bash | Latest | Windows only — needed to run the cluster setup script |

**Windows install commands (if using Chocolatey):**
```bash
choco install kind kubernetes-cli kubernetes-helm
```

Download istioctl from https://github.com/istio/istio/releases and add it to your PATH.

---

## Repository Structure After Setup

```
nestjs-microservice-example/
├── apps/
│   ├── gateway-service/
│   └── identity-service/
├── libs/
│   ├── identity/
│   └── shared/
├── docker/
│   ├── base-build.Dockerfile
│   ├── gateway-service.Dockerfile
│   ├── identity-service.Dockerfile
│   ├── docker-compose.yml
│   └── docker-compose.local.yml
├── k8s/
│   ├── scripts/
│   │   └── kind-with-registry.sh
│   ├── charts/
│   │   ├── identity-service/
│   │   └── gateway-service/
│   └── environments/
│       └── local/
│           ├── infra/
│           ├── apps/
│           └── platform/
├── CLAUDE.md
└── README.md
```

---

## Phase 1 — Local Cluster & Docker Images

### 1.1 Regenerate the package-lock.json

The lock file must be in sync before building Docker images:

```bash
npm install
```

### 1.2 Create the kind cluster with a local registry

Create `k8s/scripts/kind-with-registry.sh`:

```bash
#!/bin/bash
set -o errexit

REG_NAME='kind-registry'
REG_PORT='5001'

# Start registry container if not already running
if [ "$(docker inspect -f '{{.State.Running}}' "${REG_NAME}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${REG_PORT}:5000" --network bridge --name "${REG_NAME}" registry:2
fi

# Create the kind cluster
cat <<EOF | kind create cluster --name microservices-local --config=-
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
        [plugins."io.containerd.grpc.v1.cri".registry.mirrors."localhost:${REG_PORT}"]
          endpoint = ["http://${REG_NAME}:5000"]
EOF

# Connect registry to kind network
if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REG_NAME}")" = 'null' ]; then
  docker network connect "kind" "${REG_NAME}"
fi
```

Run it:

```bash
chmod +x k8s/scripts/kind-with-registry.sh
bash k8s/scripts/kind-with-registry.sh
```

Verify:

```bash
kubectl cluster-info --context kind-microservices-local
docker ps | grep registry
```

### 1.3 Update .dockerignore

Create/update `.dockerignore` in the repo root:

```
node_modules
dist
.git
.gitignore
*.md
.env
.env.*
docker
k8s
coverage
.nyc_output
*.log
```

### 1.4 Update docker/base-build.Dockerfile

```dockerfile
FROM node:22-alpine AS base
WORKDIR /usr/src/app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build -- --all
```

### 1.5 Fix docker/gateway-service.Dockerfile

```dockerfile
FROM node:22-alpine AS base

WORKDIR /usr/src/app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build gateway-service


FROM node:22-alpine AS production

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /usr/src/app

COPY --from=base /usr/src/app/package.json ./
COPY --from=base /usr/src/app/package-lock.json ./
COPY --from=base /usr/src/app/dist/apps/gateway-service ./dist/apps/gateway-service
COPY --from=base /usr/src/app/dist/libs ./dist/libs
COPY --from=base /usr/src/app/libs/shared/src/contracts/grpc/proto ./dist/libs/shared/src/contracts/grpc/proto

RUN npm ci --omit=dev && npm cache clean --force

USER appuser

EXPOSE 3000

CMD ["node", "dist/apps/gateway-service/src/main"]
```

### 1.6 Create docker/identity-service.Dockerfile

```dockerfile
FROM node:22-alpine AS base

WORKDIR /usr/src/app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build identity-service


FROM node:22-alpine AS production

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /usr/src/app

COPY --from=base /usr/src/app/package.json ./
COPY --from=base /usr/src/app/package-lock.json ./
COPY --from=base /usr/src/app/dist/apps/identity-service ./dist/apps/identity-service
COPY --from=base /usr/src/app/dist/libs ./dist/libs
COPY --from=base /usr/src/app/libs/shared/src/contracts/grpc/proto ./dist/libs/shared/src/contracts/grpc/proto

RUN npm ci --omit=dev && npm cache clean --force

USER appuser

EXPOSE 50051

CMD ["node", "dist/apps/identity-service/src/main"]
```

> **Why the proto COPY line?** NestJS asset copying is unreliable in Docker builds. The `.proto` file is required at runtime by both services to load the gRPC service definition. Copying it explicitly from source into the correct dist path is the reliable fix.

### 1.7 Build and push images

```bash
docker build -f docker/identity-service.Dockerfile -t localhost:5001/identity-service:0.0.1 .
docker push localhost:5001/identity-service:0.0.1

docker build -f docker/gateway-service.Dockerfile -t localhost:5001/gateway-service:0.0.1 .
docker push localhost:5001/gateway-service:0.0.1
```

Verify images are in the local registry:

```bash
curl http://localhost:5001/v2/_catalog
```

Expected: `{"repositories":["gateway-service","identity-service"]}`

---

## Phase 2 — Infrastructure Helm Charts

### 2.1 Add Helm repositories

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add nats https://nats-io.github.io/k8s/helm/charts/
helm repo update
```

### 2.2 Create PostgreSQL values

Create `k8s/environments/local/infra/postgres-values.yaml`:

```yaml
auth:
  username: postgres
  password: postgres
  database: microservices

primary:
  initdb:
    scripts:
      init-identity-schema.sql: |
        CREATE SCHEMA IF NOT EXISTS identity;
  persistence:
    size: 1Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
```

### 2.3 Create NATS values

Create `k8s/environments/local/infra/nats-values.yaml`:

```yaml
config:
  cluster:
    enabled: false
  jetstream:
    enabled: true
    fileStore:
      enabled: true
      pvc:
        size: 1Gi
```

### 2.4 Deploy PostgreSQL and NATS

```bash
helm install postgres bitnami/postgresql --namespace infra --create-namespace -f k8s/environments/local/infra/postgres-values.yaml

helm install nats nats/nats --namespace infra -f k8s/environments/local/infra/nats-values.yaml
```

Verify (wait ~60 seconds for pods to start):

```bash
kubectl get pods,pvc,svc -n infra
```

All pods should be `Running` and PVCs `Bound`.

---

## Phase 3 — Application Helm Charts

### 3.1 identity-service Helm chart

Create the following directory structure:

```
k8s/charts/identity-service/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl
    ├── serviceaccount.yaml
    ├── configmap.yaml
    ├── secret.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    └── pdb.yaml
```

**`k8s/charts/identity-service/Chart.yaml`**
```yaml
apiVersion: v2
name: identity-service
description: Identity microservice — gRPC server, CQRS, outbox pattern, PostgreSQL
type: application
version: 0.1.0
appVersion: "0.0.1"
```

**`k8s/charts/identity-service/values.yaml`**
```yaml
replicaCount: 1

image:
  repository: localhost:5001/identity-service
  tag: "0.0.1"
  pullPolicy: IfNotPresent

serviceAccount:
  create: true
  name: ""

service:
  type: ClusterIP
  port: 50051

config:
  nodeEnv: production
  grpcPort: "50051"
  identityServicePort: "50051"
  postgresHost: postgres-postgresql.infra.svc.cluster.local
  postgresPort: "5432"
  postgresDb: microservices
  natsServers: nats://nats.infra.svc.cluster.local:4222

secret:
  postgresUser: postgres
  postgresPassword: postgres

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

livenessProbe:
  initialDelaySeconds: 15
  periodSeconds: 20
  failureThreshold: 3

readinessProbe:
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3

hpa:
  enabled: false
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70

pdb:
  enabled: false
  minAvailable: 1

podAnnotations: {}
nodeSelector: {}
tolerations: []
affinity: {}
```

**`k8s/charts/identity-service/templates/_helpers.tpl`**
```
{{- define "identity-service.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "identity-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "identity-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "identity-service.labels" -}}
helm.sh/chart: {{ include "identity-service.chart" . }}
{{ include "identity-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "identity-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "identity-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
```

**`k8s/charts/identity-service/templates/serviceaccount.yaml`**
```yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "identity-service.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "identity-service.labels" . | nindent 4 }}
{{- end }}
```

**`k8s/charts/identity-service/templates/configmap.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "identity-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "identity-service.labels" . | nindent 4 }}
data:
  NODE_ENV: {{ .Values.config.nodeEnv | quote }}
  IDENTITY_SERVICE_PORT: {{ .Values.config.identityServicePort | quote }}
  GRPC_IDENTITY_PORT: {{ .Values.config.grpcPort | quote }}
  POSTGRES_HOST: {{ .Values.config.postgresHost | quote }}
  POSTGRES_PORT: {{ .Values.config.postgresPort | quote }}
  POSTGRES_DB: {{ .Values.config.postgresDb | quote }}
  NATS_SERVERS: {{ .Values.config.natsServers | quote }}
```

**`k8s/charts/identity-service/templates/secret.yaml`**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: {{ include "identity-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "identity-service.labels" . | nindent 4 }}
type: Opaque
data:
  POSTGRES_USER: {{ .Values.secret.postgresUser | b64enc | quote }}
  POSTGRES_PASSWORD: {{ .Values.secret.postgresPassword | b64enc | quote }}
```

**`k8s/charts/identity-service/templates/deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "identity-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "identity-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "identity-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "identity-service.selectorLabels" . | nindent 8 }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      serviceAccountName: {{ include "identity-service.serviceAccountName" . }}
      containers:
        - name: identity-service
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: grpc
              containerPort: 50051
              protocol: TCP
          envFrom:
            - configMapRef:
                name: {{ include "identity-service.fullname" . }}
            - secretRef:
                name: {{ include "identity-service.fullname" . }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            tcpSocket:
              port: grpc
            initialDelaySeconds: {{ .Values.livenessProbe.initialDelaySeconds }}
            periodSeconds: {{ .Values.livenessProbe.periodSeconds }}
            failureThreshold: {{ .Values.livenessProbe.failureThreshold }}
          readinessProbe:
            tcpSocket:
              port: grpc
            initialDelaySeconds: {{ .Values.readinessProbe.initialDelaySeconds }}
            periodSeconds: {{ .Values.readinessProbe.periodSeconds }}
            failureThreshold: {{ .Values.readinessProbe.failureThreshold }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

**`k8s/charts/identity-service/templates/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "identity-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "identity-service.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "identity-service.selectorLabels" . | nindent 4 }}
  ports:
    - name: grpc
      port: {{ .Values.service.port }}
      targetPort: grpc
      protocol: TCP
```

**`k8s/charts/identity-service/templates/hpa.yaml`**
```yaml
{{- if .Values.hpa.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "identity-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "identity-service.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "identity-service.fullname" . }}
  minReplicas: {{ .Values.hpa.minReplicas }}
  maxReplicas: {{ .Values.hpa.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}
{{- end }}
```

**`k8s/charts/identity-service/templates/pdb.yaml`**
```yaml
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "identity-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "identity-service.labels" . | nindent 4 }}
spec:
  minAvailable: {{ .Values.pdb.minAvailable }}
  selector:
    matchLabels:
      {{- include "identity-service.selectorLabels" . | nindent 6 }}
{{- end }}
```

---

### 3.2 gateway-service Helm chart

Create the following directory structure:

```
k8s/charts/gateway-service/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── _helpers.tpl
    ├── serviceaccount.yaml
    ├── configmap.yaml
    ├── deployment.yaml
    ├── service.yaml
    ├── hpa.yaml
    └── pdb.yaml
```

> No `secret.yaml` — gateway-service has no sensitive credentials.

**`k8s/charts/gateway-service/Chart.yaml`**
```yaml
apiVersion: v2
name: gateway-service
description: Gateway microservice — HTTP REST entry point, gRPC client to identity-service, NATS subscriber
type: application
version: 0.1.0
appVersion: "0.0.1"
```

**`k8s/charts/gateway-service/values.yaml`**
```yaml
replicaCount: 1

image:
  repository: localhost:5001/gateway-service
  tag: "0.0.1"
  pullPolicy: IfNotPresent

serviceAccount:
  create: true
  name: ""

service:
  type: ClusterIP
  port: 3000

config:
  nodeEnv: production
  port: "3000"
  grpcIdentityUrl: identity-service.microservices.svc.cluster.local:50051
  natsServers: nats://nats.infra.svc.cluster.local:4222

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 256Mi

livenessProbe:
  initialDelaySeconds: 15
  periodSeconds: 20
  failureThreshold: 3

readinessProbe:
  initialDelaySeconds: 5
  periodSeconds: 10
  failureThreshold: 3

hpa:
  enabled: false
  minReplicas: 1
  maxReplicas: 3
  targetCPUUtilizationPercentage: 70

pdb:
  enabled: false
  minAvailable: 1

podAnnotations: {}
nodeSelector: {}
tolerations: []
affinity: {}
```

**`k8s/charts/gateway-service/templates/_helpers.tpl`**
```
{{- define "gateway-service.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "gateway-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "gateway-service.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "gateway-service.labels" -}}
helm.sh/chart: {{ include "gateway-service.chart" . }}
{{ include "gateway-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "gateway-service.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "gateway-service.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
```

**`k8s/charts/gateway-service/templates/serviceaccount.yaml`**
```yaml
{{- if .Values.serviceAccount.create }}
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ include "gateway-service.serviceAccountName" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "gateway-service.labels" . | nindent 4 }}
{{- end }}
```

**`k8s/charts/gateway-service/templates/configmap.yaml`**
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "gateway-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "gateway-service.labels" . | nindent 4 }}
data:
  NODE_ENV: {{ .Values.config.nodeEnv | quote }}
  PORT: {{ .Values.config.port | quote }}
  GRPC_IDENTITY_URL: {{ .Values.config.grpcIdentityUrl | quote }}
  NATS_SERVERS: {{ .Values.config.natsServers | quote }}
```

**`k8s/charts/gateway-service/templates/deployment.yaml`**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "gateway-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "gateway-service.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "gateway-service.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "gateway-service.selectorLabels" . | nindent 8 }}
      {{- with .Values.podAnnotations }}
      annotations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
    spec:
      serviceAccountName: {{ include "gateway-service.serviceAccountName" . }}
      containers:
        - name: gateway-service
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - name: http
              containerPort: 3000
              protocol: TCP
          envFrom:
            - configMapRef:
                name: {{ include "gateway-service.fullname" . }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          livenessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: {{ .Values.livenessProbe.initialDelaySeconds }}
            periodSeconds: {{ .Values.livenessProbe.periodSeconds }}
            failureThreshold: {{ .Values.livenessProbe.failureThreshold }}
          readinessProbe:
            tcpSocket:
              port: http
            initialDelaySeconds: {{ .Values.readinessProbe.initialDelaySeconds }}
            periodSeconds: {{ .Values.readinessProbe.periodSeconds }}
            failureThreshold: {{ .Values.readinessProbe.failureThreshold }}
      {{- with .Values.nodeSelector }}
      nodeSelector:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.affinity }}
      affinity:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      {{- with .Values.tolerations }}
      tolerations:
        {{- toYaml . | nindent 8 }}
      {{- end }}
```

**`k8s/charts/gateway-service/templates/service.yaml`**
```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "gateway-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "gateway-service.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  selector:
    {{- include "gateway-service.selectorLabels" . | nindent 4 }}
  ports:
    - name: http
      port: {{ .Values.service.port }}
      targetPort: http
      protocol: TCP
```

**`k8s/charts/gateway-service/templates/hpa.yaml`**
```yaml
{{- if .Values.hpa.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "gateway-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "gateway-service.labels" . | nindent 4 }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "gateway-service.fullname" . }}
  minReplicas: {{ .Values.hpa.minReplicas }}
  maxReplicas: {{ .Values.hpa.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.hpa.targetCPUUtilizationPercentage }}
{{- end }}
```

**`k8s/charts/gateway-service/templates/pdb.yaml`**
```yaml
{{- if .Values.pdb.enabled }}
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: {{ include "gateway-service.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "gateway-service.labels" . | nindent 4 }}
spec:
  minAvailable: {{ .Values.pdb.minAvailable }}
  selector:
    matchLabels:
      {{- include "gateway-service.selectorLabels" . | nindent 6 }}
{{- end }}
```

---

### 3.3 Local environment override values

**`k8s/environments/local/apps/identity-service-values.yaml`**
```yaml
config:
  nodeEnv: development
```

**`k8s/environments/local/apps/gateway-service-values.yaml`**
```yaml
config:
  nodeEnv: development
```

> `NODE_ENV: development` enables TypeORM `synchronize: true` which auto-creates the database tables on startup. This replaces running migrations manually in local dev.

### 3.4 Dry-run both charts before installing

```bash
helm template identity-service k8s/charts/identity-service --namespace microservices
helm template gateway-service k8s/charts/gateway-service --namespace microservices
```

Each should render without errors before proceeding.

### 3.5 Install both services

```bash
helm install identity-service k8s/charts/identity-service --namespace microservices --create-namespace -f k8s/environments/local/apps/identity-service-values.yaml

helm install gateway-service k8s/charts/gateway-service --namespace microservices -f k8s/environments/local/apps/gateway-service-values.yaml
```

Watch pods come up:

```bash
kubectl get pods -n microservices -w
```

Both pods should reach `1/1 Running`. This may take 30-60 seconds.

### 3.6 Smoke test

Port-forward to test directly:

```bash
kubectl port-forward -n microservices svc/gateway-service 3000:3000
```

In a separate terminal:

```bash
# Create a user
curl -X POST http://localhost:3000/users -H "Content-Type: application/json" -d "{\"email\": \"test@example.com\", \"password\": \"password123\"}"

# Expected response: {"id":"<uuid>"}
```

---

## Phase 4 — Kubernetes Gateway API & TLS

### 4.1 Install Gateway API CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.2.0/standard-install.yaml
```

Verify:

```bash
kubectl get crd gateways.gateway.networking.k8s.io
```

### 4.2 Install Istio

```bash
istioctl install --set profile=minimal -y
```

This installs only `istiod` (the control plane). Istio automatically provisions an Envoy proxy when a `Gateway` resource is created.

Verify:

```bash
kubectl get pods -n istio-system
```

`istiod` pod should be `Running`.

### 4.3 Install cert-manager

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.3/cert-manager.yaml
```

Wait for it to be ready:

```bash
kubectl wait --for=condition=Available --timeout=120s deployment/cert-manager -n cert-manager
kubectl wait --for=condition=Available --timeout=120s deployment/cert-manager-webhook -n cert-manager
```

### 4.4 Create the istio-ingress namespace

```bash
kubectl create namespace istio-ingress
```

### 4.5 Create platform manifests

**`k8s/environments/local/platform/cert-issuer.yaml`**
```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
```

**`k8s/environments/local/platform/gateway-tls-cert.yaml`**
```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-tls
  namespace: istio-ingress
spec:
  secretName: gateway-tls-secret
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
  dnsNames:
    - microservices.local
```

**`k8s/environments/local/platform/gateway.yaml`**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: microservices-gateway
  namespace: istio-ingress
spec:
  gatewayClassName: istio
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: gateway-tls-secret
      allowedRoutes:
        namespaces:
          from: All
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
```

**`k8s/environments/local/platform/httproute.yaml`**
```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: microservices-route
  namespace: microservices
spec:
  parentRefs:
    - name: microservices-gateway
      namespace: istio-ingress
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: gateway-service
          port: 3000
```

### 4.6 Apply platform manifests

```bash
kubectl apply -f k8s/environments/local/platform/cert-issuer.yaml
kubectl apply -f k8s/environments/local/platform/gateway-tls-cert.yaml
kubectl apply -f k8s/environments/local/platform/gateway.yaml
kubectl apply -f k8s/environments/local/platform/httproute.yaml
```

### 4.7 Verify

```bash
kubectl get gateway -n istio-ingress
kubectl get certificate -n istio-ingress
kubectl get httproute -n microservices
kubectl get pods,svc -n istio-ingress
```

Expected:
- Certificate `READY: True`
- Istio pod `1/1 Running`
- Service `microservices-gateway-istio` with NodePorts for 443 and 80
- Gateway `PROGRAMMED: False` — this is normal in kind (no cloud load balancer to assign an external IP). Traffic routing still works.

### 4.8 Test HTTPS through the gateway

Port-forward the Istio gateway service:

```bash
kubectl port-forward svc/microservices-gateway-istio 8443:443 -n istio-ingress
```

In a separate terminal:

```bash
# Create a user over HTTPS
curl -k -X POST https://localhost:8443/users -H "Content-Type: application/json" -d "{\"email\": \"phase4@example.com\", \"password\": \"password123\"}"

# Fetch the user (replace <id> with the returned id)
curl -k https://localhost:8443/users/<id>
```

The `-k` flag skips certificate verification since the cert is self-signed.

---

## Restarting After a PC Reboot

kind and Docker containers stop when you shut down. On restart:

1. Start Docker Desktop
2. Verify the cluster is back:
   ```bash
   kubectl cluster-info --context kind-microservices-local
   ```
3. Check infra pods (they restart automatically):
   ```bash
   kubectl get pods -n infra
   ```
4. Check the local registry is running:
   ```bash
   docker ps | grep registry
   ```
   If not running:
   ```bash
   docker start kind-registry
   ```
5. App pods in `microservices` namespace also restart automatically. Check:
   ```bash
   kubectl get pods -n microservices
   ```

---

## Troubleshooting

### Pod is in CrashLoopBackOff

```bash
kubectl logs -n microservices deployment/<service-name>
```

Common causes:

| Error | Fix |
|---|---|
| `Cannot find module '.../main'` | The CMD path in the Dockerfile is wrong. Ensure it ends with `/src/main` not just `/main`. |
| `.proto file not found` | The proto COPY line is missing from the Dockerfile. See Sections 1.5 and 1.6. |
| `npm ci` fails during Docker build | Run `npm install` locally to regenerate `package-lock.json`, then rebuild. |

### Rebuilt image not being picked up by Kubernetes

`imagePullPolicy: IfNotPresent` means Kubernetes won't re-pull an image with the same tag. Always use a new tag when rebuilding:

```bash
docker build ... -t localhost:5001/identity-service:0.0.2 .
docker push localhost:5001/identity-service:0.0.2
helm upgrade identity-service k8s/charts/identity-service --namespace microservices -f k8s/environments/local/apps/identity-service-values.yaml --set image.tag=0.0.2
```

### Git Bash path conversion on Windows

Git Bash converts Linux paths like `/usr/src/app` to Windows paths. Prefix Docker commands with:

```bash
MSYS_NO_PATHCONV=1 docker run ...
```

### Helm install went to wrong namespace

If you accidentally install to `default` instead of `microservices`, uninstall and reinstall:

```bash
helm uninstall <release-name> --namespace default
helm install <release-name> ... --namespace microservices
```

### Multi-line Helm commands in Git Bash

Backtick `` ` `` is PowerShell's line continuation — it does not work in Git Bash. Use single-line commands instead:

```bash
helm install identity-service k8s/charts/identity-service --namespace microservices --create-namespace -f k8s/environments/local/apps/identity-service-values.yaml
```
