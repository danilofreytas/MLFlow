# MLflow no Kubernetes

Deploy do [MLflow Tracking Server](https://mlflow.org/docs/latest/ml/getting-started/running-notebooks/) em um cluster Kubernetes on-premise, usando o **chart oficial** do projeto MLflow.

Documentação do chart: [Kubernetes Helm Deployment](https://mlflow.org/docs/latest/self-hosting/kubernetes-helm/)

## Estrutura

| Arquivo | Descrição |
|---------|-----------|
| `chart/` | Chart oficial MLflow (copiado do repositório upstream) |
| `values-mark-server.yaml` | Lab: SQLite + PVC + NodePort |
| `values-production.yaml` | Produção: PostgreSQL + S3/MinIO + Ingress |
| `instalar-mlflow.sh` | Script de install/upgrade/status |
| `pv-mlflow.yaml` | Exemplo de PersistentVolume local (ajuste host/path ao seu cluster) |
| `testar-mlflow.py` | Smoke test Python (log param + metric) |

## Pré-requisitos

- `kubectl` configurado para o cluster alvo
- Helm 3.8+
- StorageClass compatível com o modo escolhido (lab com PVC local ou provisioner dinâmico)

Variáveis usadas nos exemplos abaixo (ajuste ao seu ambiente):

```bash
export KUBE_CONTEXT="seu-contexto-kubectl"
export NODE_IP="ip-do-node-kubernetes"   # ex.: IP do control plane na LAN
```

## Instalação (modo lab — recomendado para começar)

```bash
git clone git@github.com:danilofreytas/MLFlow.git
cd MLFlow

# Se o cluster usa PV estático (sem provisioner), aplique e adapte pv-mlflow.yaml
kubectl --context "$KUBE_CONTEXT" apply -f pv-mlflow.yaml

chmod +x instalar-mlflow.sh
KUBE_CONTEXT="$KUBE_CONTEXT" ./instalar-mlflow.sh install
```

Se o PVC ficar `Pending` após reinstall, libere o PV (quando a policy for `Retain`):

```bash
kubectl --context "$KUBE_CONTEXT" patch pv mlflow-pv -p '{"spec":{"claimRef": null}}'
kubectl --context "$KUBE_CONTEXT" -n mlflow delete pod -l app.kubernetes.io/name=mlflow
```

Isso cria o namespace `mlflow`, instala o release `mlflow` e expõe a UI via **NodePort**.

### Acessar a UI

```bash
kubectl --context "$KUBE_CONTEXT" -n mlflow get svc mlflow-mlflow
```

Com NodePort:

```bash
NODE_PORT=$(kubectl --context "$KUBE_CONTEXT" -n mlflow get svc mlflow-mlflow -o jsonpath='{.spec.ports[0].nodePort}')
echo "http://${NODE_IP}:${NODE_PORT}"
```

Ou via port-forward local:

```bash
kubectl --context "$KUBE_CONTEXT" -n mlflow port-forward svc/mlflow-mlflow 5000:5000
# UI: http://127.0.0.1:5000
```

## Testar a aplicação

```bash
python3 -m venv .venv
source .venv/bin/activate   # Windows: .venv\Scripts\activate
pip install "mlflow>=3.1"

NODE_PORT=$(kubectl --context "$KUBE_CONTEXT" -n mlflow get svc mlflow-mlflow -o jsonpath='{.spec.ports[0].nodePort}')
export MLFLOW_TRACKING_URI="http://${NODE_IP}:${NODE_PORT}"
python testar-mlflow.py
```

## Conectar notebooks / scripts Python

Conforme a [documentação de getting started](https://mlflow.org/docs/latest/ml/getting-started/running-notebooks/):

```bash
pip install --upgrade "mlflow>=3.1"
```

```python
import mlflow

mlflow.set_tracking_uri("http://<NODE_IP>:<NODE_PORT>")  # ou http://127.0.0.1:5000 com port-forward
mlflow.set_experiment("meu-primeiro-experimento")

with mlflow.start_run():
    mlflow.log_param("test_param", "ok")
    mlflow.log_metric("accuracy", 0.95)
    print("Conectado ao MLflow no K8s")
```

Ou via variáveis de ambiente:

```bash
export MLFLOW_TRACKING_URI="http://<NODE_IP>:<NODE_PORT>"
export MLFLOW_EXPERIMENT_NAME="meu-primeiro-experimento"
```

## Modo produção (PostgreSQL + S3)

1. Crie os secrets:

```bash
kubectl --context "$KUBE_CONTEXT" create namespace mlflow --dry-run=client -o yaml | kubectl apply -f -

kubectl --context "$KUBE_CONTEXT" -n mlflow create secret generic mlflow-db-secret \
  --from-literal=uri='postgresql://mlflow:SENHA@postgres.mlflow.svc:5432/mlflow'

kubectl --context "$KUBE_CONTEXT" -n mlflow create secret generic mlflow-s3-credentials \
  --from-literal=access-key-id='MINIO_ACCESS_KEY' \
  --from-literal=secret-access-key='MINIO_SECRET_KEY' \
  --from-literal=endpoint-url='http://minio.mlflow.svc:9000'
```

2. Instale com os values de produção:

```bash
KUBE_CONTEXT="$KUBE_CONTEXT" VALUES_FILE=values-production.yaml ./instalar-mlflow.sh install
```

> SQLite + PVC **não** é adequado para multi-usuário ou alta concorrência. Use PostgreSQL + object store em produção.

## Comandos úteis

```bash
./instalar-mlflow.sh status
./instalar-mlflow.sh template    # renderiza manifests sem aplicar
./instalar-mlflow.sh uninstall
```

## Atualizar chart upstream

Para sincronizar com uma versão mais nova do chart oficial:

```bash
cd /tmp && rm -rf mlflow-chart-dl && mkdir mlflow-chart-dl && cd mlflow-chart-dl
for f in Chart.yaml values.yaml example-mlflow-charts.yaml README.md; do
  curl -fsSL "https://raw.githubusercontent.com/mlflow/mlflow/master/charts/$f" -o "$f"
done
curl -fsSL "https://api.github.com/repos/mlflow/mlflow/contents/charts/templates" | python3 -c "
import json,sys,urllib.request,os
for x in json.load(sys.stdin):
    os.makedirs('templates', exist_ok=True)
    urllib.request.urlretrieve(x['download_url'], 'templates/'+x['name'])
"
helm lint .
cp -R /tmp/mlflow-chart-dl/* ./chart/   # execute a partir da raiz do repositório clonado
```

## Troubleshooting

| Sintoma | Causa provável | Ação |
|---------|----------------|------|
| `connection refused` em `:6443` | API server do K8s parado | Verifique o control plane e o kubelet no node |
| Pod `Pending` | Sem StorageClass / PVC | `kubectl get sc`; ajuste `storage.storageClassName` |
| Pod `OOMKilled` | Memória insuficiente | Aumente `resources.limits.memory` e reduza `workers` |
| HTTP 403 no Ingress | Host não permitido | Defina `server.value_options.allowed_hosts` |
| `ImagePullBackOff` | Sem acesso ao ghcr.io | Espelhe a imagem ou configure `imagePullSecrets` |
