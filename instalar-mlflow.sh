#!/usr/bin/env bash
# Instala ou atualiza MLflow no Kubernetes (chart oficial MLflow).
# Uso padrão: cluster on-prem mark-server (192.168.15.56).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART_DIR="${SCRIPT_DIR}/chart"
NAMESPACE="${NAMESPACE:-mlflow}"
RELEASE="${RELEASE:-mlflow}"
CTX="${KUBE_CONTEXT:-mark-server}"
VALUES_FILE="${VALUES_FILE:-${SCRIPT_DIR}/values-mark-server.yaml}"

usage() {
  cat <<'EOF'
Uso: ./instalar-mlflow.sh [install|upgrade|template|status|uninstall]

Variáveis de ambiente:
  KUBE_CONTEXT   contexto kubectl (padrão: mark-server)
  NAMESPACE      namespace (padrão: mlflow)
  RELEASE        nome do release Helm (padrão: mlflow)
  VALUES_FILE    arquivo values (padrão: values-mark-server.yaml)

Exemplos:
  ./instalar-mlflow.sh install
  VALUES_FILE=values-production.yaml ./instalar-mlflow.sh install
  ./instalar-mlflow.sh status
EOF
}

ensure_context() {
  if ! kubectl config get-contexts "$CTX" &>/dev/null; then
    echo "Contexto '$CTX' não encontrado no kubeconfig." >&2
    exit 1
  fi

  # Corrige contexto mark-server se apontar para cluster/user inexistentes.
  local cluster user
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CTX}')].context.cluster}")"
  user="$(kubectl config view -o jsonpath="{.contexts[?(@.name=='${CTX}')].context.user}")"
  if ! kubectl config get-clusters "$cluster" &>/dev/null 2>&1; then
    if kubectl config get-clusters kubernetes &>/dev/null 2>&1; then
      kubectl config set-context "$CTX" --cluster=kubernetes --user="${user:-kubernetes-admin}" --namespace="$NAMESPACE"
    fi
  fi
  if ! kubectl config get-users "$user" &>/dev/null 2>&1; then
    if kubectl config get-users kubernetes-admin &>/dev/null 2>&1; then
      kubectl config set-context "$CTX" --cluster="${cluster:-kubernetes}" --user=kubernetes-admin --namespace="$NAMESPACE"
    fi
  fi
}

preflight() {
  command -v helm >/dev/null || { echo "helm não encontrado" >&2; exit 1; }
  command -v kubectl >/dev/null || { echo "kubectl não encontrado" >&2; exit 1; }
  [[ -f "$VALUES_FILE" ]] || { echo "Values não encontrado: $VALUES_FILE" >&2; exit 1; }
  [[ -d "$CHART_DIR" ]] || { echo "Chart não encontrado: $CHART_DIR" >&2; exit 1; }

  ensure_context
  echo "==> Contexto: $CTX | Namespace: $NAMESPACE | Release: $RELEASE"
  kubectl --context="$CTX" cluster-info
  kubectl --context="$CTX" get storageclass 2>/dev/null || true
}

install_or_upgrade() {
  preflight
  helm upgrade --install "$RELEASE" "$CHART_DIR" \
    --kube-context "$CTX" \
    --namespace "$NAMESPACE" \
    --create-namespace \
    -f "$VALUES_FILE" \
    --wait \
    --timeout 10m

  echo
  echo "==> Pods"
  kubectl --context="$CTX" -n "$NAMESPACE" get pods -o wide
  echo
  echo "==> Service"
  kubectl --context="$CTX" -n "$NAMESPACE" get svc
  echo
  show_access_hint
}

show_access_hint() {
  local svc_type node_port
  svc_type="$(kubectl --context="$CTX" -n "$NAMESPACE" get svc "${RELEASE}-mlflow" -o jsonpath='{.spec.type}' 2>/dev/null || true)"
  if [[ "$svc_type" == "NodePort" ]]; then
    node_port="$(kubectl --context="$CTX" -n "$NAMESPACE" get svc "${RELEASE}-mlflow" -o jsonpath='{.spec.ports[0].nodePort}')"
    echo "UI na LAN: http://192.168.15.56:${node_port}"
    echo "Tracking URI Python:"
    echo "  export MLFLOW_TRACKING_URI=http://192.168.15.56:${node_port}"
  else
    echo "Port-forward local:"
    echo "  kubectl --context=$CTX -n $NAMESPACE port-forward svc/${RELEASE}-mlflow 5000:5000"
    echo "  export MLFLOW_TRACKING_URI=http://127.0.0.1:5000"
  fi
}

render_template() {
  preflight
  helm template "$RELEASE" "$CHART_DIR" \
    --namespace "$NAMESPACE" \
    -f "$VALUES_FILE"
}

show_status() {
  ensure_context
  kubectl --context="$CTX" -n "$NAMESPACE" get all
  show_access_hint
}

uninstall_release() {
  ensure_context
  helm uninstall "$RELEASE" --kube-context "$CTX" --namespace "$NAMESPACE"
  echo "PVCs não são removidos automaticamente. Para apagar dados:"
  echo "  kubectl --context=$CTX -n $NAMESPACE delete pvc --all"
}

ACTION="${1:-install}"
case "$ACTION" in
  install|upgrade) install_or_upgrade ;;
  template) render_template ;;
  status) show_status ;;
  uninstall) uninstall_release ;;
  -h|--help|help) usage ;;
  *) echo "Ação inválida: $ACTION" >&2; usage; exit 1 ;;
esac
