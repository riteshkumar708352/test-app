#!/usr/bin/env bash
# =============================================================================
#  deploy-nexure-all.sh
#  ONE self-contained, idempotent deploy for the entire nexure-ai-prod stack on VKS:
#  namespace + ConfigMaps + Secrets + Deployments + NodePort Services + Citrix Ingresses,
#  Weaviate (PVC + workload + service), and neo4j (Deployment + PVC + service).
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------------ Tunables --
NAMESPACE="${NAMESPACE:-bajajlife-elam}"
CITRIX_VIP="10.3.10.160"
DOMAIN_SUFFIX="bajajlife.com"
CERT_KEY_NAME="star_bajajlife_com_nov2025"

VKS_REGISTRY_HOST="${VKS_REGISTRY_HOST:-l1srv2vksimg.bajajlife.com}"
VKS_REGISTRY="${VKS_REGISTRY:-l1srv2vksimg.bajajlife.com/bajajlife}"
NEO4J_STORAGE_CLASS="${NEO4J_STORAGE_CLASS:-vsphere-csi-sc}" 
WEAVIATE_STORAGE_CLASS="${WEAVIATE_STORAGE_CLASS:-vsphere-csi-sc}"

# Latest image tag per service
declare -A IMG=(
  [admin-api]=v2000  [analytics-api]=v2000  [frontend-api]=v2000  [integration-api]=v2000
  [login-api]=v2000  [testcase-api]=v2000   [workflow-api]=v2000  [workorder-api]=v2000
)

# =========================================================== CREDENTIALS ======
NEON_DATABASE_URL="postgresql://neondb_owner:npg_8rUT9zHpSDdO@ep-shy-salad-adbu4mse-pooler.c-2.us-east-1.aws.neon.tech/neondb?sslmode=require&channel_binding=require"
NEON_DATABASE_URL_PSYCOPG="postgresql+psycopg://neondb_owner:npg_8rUT9zHpSDdO@ep-shy-salad-adbu4mse-pooler.c-2.us-east-1.aws.neon.tech/neondb?sslmode=require&channel_binding=require"

INTEGRATION_SECRET_KEY="change-this-to-a-random-secret-key-in-production"


# ==============================================================================

# ------------------------------------------------------------------ Helpers --
apply() { kubectl apply -f - ; }
cm()  { kubectl create configmap "$1" -n "$NAMESPACE" "${@:2}" --dry-run=client -o yaml | apply ; }
sec() { kubectl create secret generic "$1" -n "$NAMESPACE" "${@:2}" --dry-run=client -o yaml | apply ; }
ensure_namespace() { kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || kubectl create namespace "$NAMESPACE"; }

# =========================================== (optional) image build + push ====
push_images() {
  podman login "$VKS_REGISTRY_HOST"
  for svc in "${!IMG[@]}"; do
    tag="${IMG[$svc]}"
    podman tag  "${VKS_REGISTRY}/${svc}:${tag}" "${VKS_REGISTRY}/${svc}:${tag}"
    podman push "${VKS_REGISTRY}/${svc}:${tag}"
  done
}

# ================================================== ConfigMaps + Secrets ======
config_and_secrets() {
  cm admin-api-config \
    --from-literal=PORT=8000 --from-literal=HOST=0.0.0.0 \
    --from-literal=ENVIRONMENT=production --from-literal=LOG_LEVEL=INFO --from-literal=API_VERSION=v1 \
    --from-literal=ACCESS_TOKEN_EXPIRE_MINUTES=60 --from-literal=REFRESH_TOKEN_EXPIRE_MINUTES=1440 \
    --from-literal=DB_POOL_SIZE=20 --from-literal=DB_MAX_OVERFLOW=30 \
    --from-literal=DB_POOL_TIMEOUT=30 --from-literal=DB_POOL_RECYCLE=3600 \
    --from-literal=ALGORITHM=HS256 --from-literal=DB_ECHO=false
  sec admin-api-secrets \
    --from-literal=SECRET_KEY="$SHARED_SECRET_KEY" --from-literal=DATABASE_URL="$NEON_DATABASE_URL"

  cm analytics-api-config \
    --from-literal=PORT=8000 --from-literal=HOST=0.0.0.0 \
    --from-literal=ENVIRONMENT=development --from-literal=LOG_LEVEL=INFO --from-literal=API_VERSION=v1 \
    --from-literal=ACCESS_TOKEN_EXPIRE_MINUTES=60 --from-literal=REFRESH_TOKEN_EXPIRE_MINUTES=1440 \
    --from-literal=DB_POOL_SIZE=20 --from-literal=DB_MAX_OVERFLOW=30 \
    --from-literal=DB_POOL_TIMEOUT=30 --from-literal=DB_POOL_RECYCLE=3600 \
    --from-literal=ALGORITHM=HS256 --from-literal=DB_ECHO=false
  sec analytics-api-secrets \
    --from-literal=SECRET_KEY="$SHARED_SECRET_KEY" --from-literal=DATABASE_URL="$NEON_DATABASE_URL"

  cm frontend-api-config \
    --from-literal=NEXT_PUBLIC_LOGIN_API_BASE_URL=https://login-api.${DOMAIN_SUFFIX} \
    --from-literal=NEXT_PUBLIC_TEST_CASE_API_BASE_URL=https://testcase-api.${DOMAIN_SUFFIX} \
    --from-literal=NEXT_PUBLIC_ADMIN_API_BASE_URL=https://analytics-api.${DOMAIN_SUFFIX} \
    --from-literal=NEXT_PUBLIC_ADMIN_CREATION_API_BASE_URL=https://admin-api.${DOMAIN_SUFFIX} \
    --from-literal=NEXT_PUBLIC_TEST_CASE_CRUD_API_BASE_URL=https://workflow-api.${DOMAIN_SUFFIX} \
    --from-literal=NEXT_PUBLIC_WORK_ORDER_API_BASE_URL=https://workorder-api.${DOMAIN_SUFFIX} \
    --from-literal=REFRESH_TOKEN_EXPIRE_MINUTES=1400
  sec frontend-api-secrets \
    --from-literal=SECRET_KEY="$FRONTEND_TESTCASE_SECRET_KEY" --from-literal=DATABASE_URL="$NEON_DATABASE_URL"

  cm integration-api-config \
    --from-literal=APP_NAME="Integration API" --from-literal=APP_VERSION=1.0.0 \
  sec integration-api-secrets \
    --from-literal=SECRET_KEY="$INTEGRATION_SECRET_KEY" \
    --from-literal=DATABASE_URL="$NEON_DATABASE_URL_PSYCOPG" \
    --from-literal=MICROSOFT_CLIENT_SECRET="$MICROSOFT_CLIENT_SECRET"

  cm login-api-config \
    --from-literal=PORT=8000 --from-literal=HOST=0.0.0.0 \
    --from-literal=ENVIRONMENT=production --from-literal=LOG_LEVEL=INFO --from-literal=API_VERSION=v1 \
    --from-literal=ACCESS_TOKEN_EXPIRE_MINUTES=60 --from-literal=REFRESH_TOKEN_EXPIRE_MINUTES=1440 \
    --from-literal=DB_POOL_SIZE=20 --from-literal=DB_MAX_OVERFLOW=30 \
    --from-literal=DB_POOL_TIMEOUT=30 --from-literal=DB_POOL_RECYCLE=3600 \
    --from-literal=ALGORITHM=HS256 --from-literal=ALLOWED_ORIGINS=https://nexureai.in
  sec login-api-secrets \
    --from-literal=SECRET_KEY="$SHARED_SECRET_KEY" --from-literal=DATABASE_URL="$NEON_DATABASE_URL"

  cm testcase-api-config \
    --from-literal=PORT=8000 --from-literal=HOST=0.0.0.0 \
    --from-literal=ENVIRONMENT=production --from-literal=LOG_LEVEL=INFO --from-literal=API_VERSION=v1 \
    --from-literal=ACCESS_TOKEN_EXPIRE_MINUTES=1440 --from-literal=REFRESH_TOKEN_EXPIRE_MINUTES=1400 \
    --from-literal=DB_ECHO=false --from-literal=DB_POOL_SIZE=20 \
    --from-literal=DB_MAX_OVERFLOW=30 --from-literal=DB_POOL_TIMEOUT=30 --from-literal=DB_POOL_RECYCLE=3600 \
    --from-literal=WEAVIATE_URL=http://weaviate.${NAMESPACE}.svc.cluster.local:8080 \
    --from-literal=RAG_EMBEDDING_MODEL=text-embedding-3-small --from-literal=RAG_EMBEDDING_DIM=1536 \
    --from-literal=LLM_AZURE_ENDPOINT='https://soume-mfqf36kj-eastus2.cognitiveservices.azure.com/openai/deployments/text-embedding-3-small/embeddings?api-version=2023-05-15' \
    --from-literal=LLM_AZURE_API_VERSION=2024-02-15-preview \
    --from-literal=AZURE_OPENAI_ENDPOINT_1='https://soume-mkibnm2g-eastus.cognitiveservices.azure.com/openai/deployments/gpt-5-nano/chat/completions' \
    --from-literal=AZURE_OPENAI_ENDPOINT_2='https://soume-mkm3biqd-southeastasia.cognitiveservices.azure.com/openai/deployments/gpt-5-nano/chat/completions' \
    --from-literal=AZURE_OPENAI_ENDPOINT_3='https://soume-mfqf36kj-eastus2.cognitiveservices.azure.com/openai/deployments/gpt-5-nano/chat/completions' \
    --from-literal=AZURE_RPM=65 --from-literal=AZURE_OPENAI_API_VERSION=2025-01-01-preview \
    --from-literal=AZURE_OPENAI_TPM_LIMIT=60000 \
    --from-literal=AZURE_OPENAI_TPM_LIMIT_1=200000 --from-literal=AZURE_OPENAI_TPM_LIMIT_2=200000 \
    --from-literal=AZURE_OPENAI_TPM_LIMIT_3=200000 \
    --from-literal=CONTAINER_NAME=documents --from-literal=ENABLE_LANGFUSE=true \
    --from-literal=LANGFUSE_ENDPOINT=https://cloud.langfuse.com --from-literal=DEBUG=false \
    --from-literal=WORKFLOW_SERVICE_TOKEN_PROVIDER=true
  sec testcase-api-secrets \
    --from-literal=SECRET_KEY="$FRONTEND_TESTCASE_SECRET_KEY" \
    --from-literal=DATABASE_URL="$NEON_DATABASE_URL" \
    --from-literal=AZURE_OPENAI_API_KEY_1="$TESTCASE_AZURE_OPENAI_API_KEY_1" \
    --from-literal=AZURE_OPENAI_API_KEY_2="$TESTCASE_AZURE_OPENAI_API_KEY_2" \
    --from-literal=AZURE_OPENAI_API_KEY_3="$TESTCASE_AZURE_OPENAI_API_KEY_3" \
    --from-literal=AZURE_STORAGE_CONNECTION_STRING="$AZURE_STORAGE_CONNECTION_STRING" \
    --from-literal=LANGFUSE_SECRET_KEY="$LANGFUSE_SECRET_KEY" \
    --from-literal=LANGFUSE_PUBLIC_KEY="$LANGFUSE_PUBLIC_KEY" \
    --from-literal=WORKFLOW_SERVICE_ACCOUNT_LOGIN_URL="https://login-api.${DOMAIN_SUFFIX}/auth/login" \
    --from-literal=WORKFLOW_SERVICE_ACCOUNT_EMAIL="santosh@zetamicron.com" \
    --from-literal=WORKFLOW_SERVICE_ACCOUNT_PASSWORD="$WORKFLOW_SERVICE_ACCOUNT_PASSWORD"

  cm workflow-api-config \
    --from-literal=PORT=8000 --from-literal=HOST=0.0.0.0 \
    --from-literal=ENVIRONMENT=production --from-literal=LOG_LEVEL=INFO --from-literal=API_VERSION=v1 \
    --from-literal=ALLOWED_ORIGINS='["*"]' \
    --from-literal=ACCESS_TOKEN_EXPIRE_MINUTES=60 --from-literal=REFRESH_TOKEN_EXPIRE_MINUTES=1440 \
    --from-literal=DB_POOL_SIZE=20 --from-literal=DB_MAX_OVERFLOW=30 \
    --from-literal=DB_POOL_TIMEOUT=30 --from-literal=DB_POOL_RECYCLE=3600 \
    --from-literal=ALGORITHM=HS256 --from-literal=DATABASE_SSL_REQUIRED=true \
    --from-literal=VECTOR_API_BASE_URL=http://weaviate.${NAMESPACE}.svc.cluster.local:8080 \
    --from-literal=VECTOR_API_TIMEOUT=60 --from-literal=DB_ECHO=false
  sec workflow-api-secrets \
    --from-literal=SECRET_KEY="$SHARED_SECRET_KEY" \
    --from-literal=DATABASE_URL="$NEON_DATABASE_URL" \
    --from-literal=JWT_SECRET_KEY="$SHARED_SECRET_KEY"

  cm workorder-api-config \
    --from-literal=PORT=8000 --from-literal=HOST=0.0.0.0 \
    --from-literal=ENVIRONMENT=production --from-literal=LOG_LEVEL=INFO --from-literal=API_VERSION=v1 \
    --from-literal=ALLOWED_ORIGINS='["*"]' \
    --from-literal=AZURE_CONTAINER_NAME=documents --from-literal=MAX_FILE_SIZE=10485760 \
    --from-literal=INTEGRATION_API_BASE_URL=http://integration-api.${NAMESPACE}.svc.cluster.local:80 \
    --from-literal=INTEGRATION_API_TIMEOUT=10 --from-literal=COMPANY_NAME="Nexure AI" \
    --from-literal=DB_POOL_RECYCLE=3600 --from-literal=YEAR=2025 \
    --from-literal=DATABASE_SSL_REQUIRED=true \
    --from-literal=APP_NAME="WorkOrder API" --from-literal=APP_VERSION=1.0.0 --from-literal=DEBUG=false
  sec workorder-api-secrets \
    --from-literal=AZURE_STORAGE_CONNECTION_STRING="$AZURE_STORAGE_CONNECTION_STRING" \
    --from-literal=DATABASE_URL="$NEON_DATABASE_URL" \
    --from-literal=JWT_SECRET_KEY="$SHARED_SECRET_KEY"

  cm weaviate-config \
    --from-literal=AUTHENTICATION_ANONYMOUS_ACCESS_ENABLED=true \
    --from-literal=CLUSTER_HOSTNAME=node1 \
    --from-literal=DEFAULT_VECTORIZER_MODULE=none \
    --from-literal=ENABLE_MODULES=text2vec-openai,text2vec-cohere,text2vec-huggingface,generative-openai \
    --from-literal=PERSISTENCE_DATA_PATH=/var/lib/weaviate \
    --from-literal=QUERY_DEFAULTS_LIMIT=25
}

# ==================== Deployments + NodePort Services + Citrix Ingresses =====
deploy_apps() {
  for svc in admin-api analytics-api frontend-api integration-api login-api testcase-api workflow-api workorder-api; do
    tag="${IMG[$svc]}"
    if [ "$svc" = "integration-api" ]; then port=8080; else port=8000; fi
    cat <<EOF | apply
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${svc}
  namespace: ${NAMESPACE}
  labels: { app: ${svc} }
spec:
  replicas: 1
  selector: { matchLabels: { app: ${svc} } }
  strategy:
    type: RollingUpdate
    rollingUpdate: { maxSurge: 1, maxUnavailable: 0 }
  template:
    metadata:
      labels: { app: ${svc} }
    spec:
      containers:
      - name: ${svc}
        image: ${VKS_REGISTRY}/${svc}:${tag}
        imagePullPolicy: Always
        ports:
        - { containerPort: ${port}, name: http }
        resources:
          requests: { memory: "256Mi", cpu: "250m" }
          limits:   { memory: "512Mi", cpu: "500m" }
        envFrom:
        - configMapRef: { name: ${svc}-config }
        - secretRef:    { name: ${svc}-secrets }
---
apiVersion: v1
kind: Service
metadata:
  name: ${svc}
  namespace: ${NAMESPACE}
  labels: { app: ${svc} }
spec:
  type: NodePort
  selector: { app: ${svc} }
  ports:
  - { name: http, port: 80, targetPort: ${port}, protocol: TCP }
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${svc}-ingress
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/ingress.class: "citrix"
    ingress.citrix.com/frontend-ip: "${CITRIX_VIP}"
    ingress.citrix.com/secure-port: "443"
    ingress.citrix.com/insecure-port: "80"
    ingress.citrix.com/insecure-termination: "redirect"
    ingress.citrix.com/ssl-redirect: "true"
    ingress.citrix.com/preconfigured-certkey: '{"certs": [{"name": "${CERT_KEY_NAME}", "type": "default"}]}'
    ingress.citrix.com/secure-service-type: "ssl"
spec:
  tls:
  - hosts:
    - ${svc}.${DOMAIN_SUFFIX}
  rules:
  - host: ${svc}.${DOMAIN_SUFFIX}
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ${svc}
            port:
              number: 80
EOF
  done
}

# ================================ Weaviate ====================================
deploy_weaviate() {
  cat <<EOF | apply
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: weaviate-data
  namespace: ${NAMESPACE}
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 5Gi } }
  storageClassName: ${WEAVIATE_STORAGE_CLASS}
  volumeMode: Filesystem
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: weaviate
  namespace: ${NAMESPACE}
  labels: { app: weaviate }
spec:
  serviceName: weaviate
  replicas: 1
  selector: { matchLabels: { app: weaviate } }
  template:
    metadata:
      labels: { app: weaviate }
    spec:
      containers:
      - name: weaviate
        image: cr.weaviate.io/semitechnologies/weaviate:1.25.0
        args: ["--host","0.0.0.0","--port","8080","--scheme","http"]
        ports:
        - { containerPort: 8080, name: http }
        envFrom:
        - configMapRef: { name: weaviate-config }
        volumeMounts:
        - { name: weaviate-data, mountPath: /var/lib/weaviate }
        resources:
          requests: { memory: "512Mi", cpu: "250m" }
          limits:   { memory: "2Gi",   cpu: "1" }
      volumes:
      - name: weaviate-data
        persistentVolumeClaim: { claimName: weaviate-data }
---
apiVersion: v1
kind: Service
metadata:
  name: weaviate
  namespace: ${NAMESPACE}
  labels: { app: weaviate }
spec:
  type: NodePort
  selector: { app: weaviate }
  ports:
  - { name: http, port: 8080, targetPort: 8080, protocol: TCP }
EOF
}

# ================================ neo4j =======================================
deploy_neo4j() {
  sec graph-cache-secrets \
    --from-literal=NEO4J_AUTH="$NEO4J_AUTH" \
    --from-literal=NEO4J_PASSWORD="$NEO4J_PASSWORD"
  cat <<EOF | apply
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: neo4j-data
  namespace: ${NAMESPACE}
  labels: { app: neo4j }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 10Gi } }
  storageClassName: ${NEO4J_STORAGE_CLASS}
  volumeMode: Filesystem
---
apiVersion: v1
kind: Service
metadata:
  name: neo4j
  namespace: ${NAMESPACE}
  labels: { app: neo4j }
spec:
  type: NodePort
  selector: { app: neo4j }
  ports:
  - { name: bolt, port: 7687, targetPort: 7687 }
  - { name: http, port: 7474, targetPort: 7474 }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: neo4j
  namespace: ${NAMESPACE}
  labels: { app: neo4j }
spec:
  replicas: 1
  strategy: { type: Recreate }
  selector: { matchLabels: { app: neo4j } }
  template:
    metadata:
      labels: { app: neo4j }
    spec:
      securityContext:
        fsGroup: 7474
        fsGroupChangePolicy: OnRootMismatch
      containers:
      - name: neo4j
        image: neo4j:5.26-community
        ports:
        - { name: bolt, containerPort: 7687 }
        - { name: http, containerPort: 7474 }
        env:
        - name: NEO4J_AUTH
          valueFrom: { secretKeyRef: { name: graph-cache-secrets, key: NEO4J_AUTH } }
        - name: PROBE_PASSWORD
          valueFrom: { secretKeyRef: { name: graph-cache-secrets, key: NEO4J_PASSWORD } }
        - { name: NEO4J_PLUGINS, value: '["apoc"]' }
        - { name: NEO4J_dbms_security_procedures_unrestricted, value: "apoc.*" }
        - { name: NEO4J_dbms_security_procedures_allowlist, value: "apoc.*" }
        - { name: NEO4J_server_default__listen__address, value: "0.0.0.0" }
        - { name: NEO4J_server_memory_heap_initial__size, value: "1G" }
        - { name: NEO4J_server_memory_heap_max__size, value: "2G" }
        - { name: NEO4J_server_memory_pagecache_size, value: "1G" }
        - { name: NEO4J_server_bolt_thread__pool__max__size, value: "200" }
        resources:
          requests: { cpu: "300m", memory: "3Gi" }
          limits:   { cpu: "800m", memory: "4Gi" }
        volumeMounts:
        - { name: data, mountPath: /data }
        startupProbe:
          tcpSocket: { port: 7687 }
          periodSeconds: 10
          failureThreshold: 30
        livenessProbe:
          tcpSocket: { port: 7687 }
          timeoutSeconds: 5
          periodSeconds: 20
          failureThreshold: 3
        readinessProbe:
          exec:
            command: ["/bin/sh","-c","cypher-shell -u neo4j -p \"\$PROBE_PASSWORD\" \"RETURN 1;\""]
          initialDelaySeconds: 20
          timeoutSeconds: 10
          periodSeconds: 15
          failureThreshold: 3
      volumes:
      - name: data
        persistentVolumeClaim: { claimName: neo4j-data }
EOF
}

# --------------------------------------------------------------- Orchestrate --
main() {
  ensure_namespace
  case "${1:-all}" in
    images)   push_images ;;
    apps)     config_and_secrets; deploy_apps ;;
    weaviate) config_and_secrets; deploy_weaviate ;;
    neo4j)    deploy_neo4j ;;
    all)      config_and_secrets; deploy_apps; deploy_weaviate; deploy_neo4j ;;
    *) echo "usage: $0 [all|apps|weaviate|neo4j|images]"; exit 1 ;;
  esac
  echo "Done. Objects applied to namespace '${NAMESPACE}' on VKS cluster."
}
main "$@"
