# MLflow no Kubernetes (mark-server)

Deploy do [MLflow Tracking Server](https://mlflow.org/docs/latest/ml/getting-started/running-notebooks/) no cluster on-prem `mark-server` (`https://192.168.15.56:6443`), usando o **chart oficial** do projeto MLflow.

Documentação do chart: [Kubernetes Helm Deployment](https://mlflow.org/docs/latest/self-hosting/kubernetes-helm/)

## Estrutura

| Arquivo | Descrição |
|---------|-----------|
| `chart/` | Chart oficial MLflow (copiado do repositório upstream) |
| `values-mark-server.yaml` | Lab: SQLite + PVC + NodePort |
| `values-production.yaml` | Produção: PostgreSQL + S3/MinIO + Ingress |
| `instalar-mlflow.sh` | Script de install/upgrade/status |
| `pv-mlflow.yaml` | PersistentVolume local (`/mnt/mlflow`) para o cluster mark-server |
| `testar-mlflow.py` | Smoke test Python (log param + metric) |

## Pré-requisitos

- Cluster K8s acessível (`kubectl --context mark-server cluster-info`)
- Helm 3.8+
- API server rodando em `192.168.15.56:6443`
- StorageClass com provisioner (para o PVC do modo lab)

### Corrigir contexto kubectl

Se `mark-server` falhar com `localhost:8080`, o contexto estava quebrado. Corrija com:

```bash
kubectl config set-context mark-server \
  --cluster=kubernetes \
  --user=kubernetes-admin \
  --namespace=mlflow
```

## Instalação (modo lab — recomendado para começar)

```bash
cd /Users/dreis/devops/Gromit/MLFlow

# PV local (cluster mark-server usa StorageClass local-storage sem provisioner)
kubectl --context mark-server apply -f pv-mlflow.yaml

chmod +x instalar-mlflow.sh
./instalar-mlflow.sh install
```

Se o PVC ficar `Pending` após reinstall, libere o PV:

```bash
kubectl --context mark-server patch pv mlflow-pv -p '{"spec":{"claimRef": null}}'
kubectl --context mark-server -n mlflow delete pod -l app.kubernetes.io/name=mlflow
```

Isso cria o namespace `mlflow`, instala o release `mlflow` e expõe a UI via **NodePort** na LAN.

### Acessar a UI

Após o install:

```bash
kubectl --context mark-server -n mlflow get svc mlflow-mlflow
```

Abra `http://192.168.15.56:<NODE_PORT>` ou use port-forward:

```bash
kubectl --context mark-server -n mlflow port-forward svc/mlflow-mlflow 5000:5000
```

## Testar a aplicação

```bash
cd /Users/dreis/devops/Gromit/MLFlow
python3 -m venv .venv
.venv/bin/pip install "mlflow>=3.1"

NODE_PORT=$(kubectl --context mark-server -n mlflow get svc mlflow-mlflow -o jsonpath='{.spec.ports[0].nodePort}')
export MLFLOW_TRACKING_URI="http://192.168.15.56:${NODE_PORT}"
.venv/bin/python testar-mlflow.py
```

UI: `http://192.168.15.56:<NODE_PORT>`

---

Conforme a [documentação de getting started](https://mlflow.org/docs/latest/ml/getting-started/running-notebooks/):

```bash
pip install --upgrade "mlflow>=3.1"
```

```python
import mlflow

mlflow.set_tracking_uri("http://192.168.15.56:<NODE_PORT>")  # ou http://127.0.0.1:5000 com port-forward
mlflow.set_experiment("meu-primeiro-experimento")

with mlflow.start_run():
    mlflow.log_param("test_param", "ok")
    mlflow.log_metric("accuracy", 0.95)
    print("Conectado ao MLflow no K8s")
```

Ou via variáveis de ambiente:

```bash
export MLFLOW_TRACKING_URI="http://192.168.15.56:<NODE_PORT>"
export MLFLOW_EXPERIMENT_NAME="meu-primeiro-experimento"
```

## Modo produção (PostgreSQL + S3)

1. Crie os secrets:

```bash
kubectl --context mark-server create namespace mlflow --dry-run=client -o yaml | kubectl apply -f -

kubectl --context mark-server -n mlflow create secret generic mlflow-db-secret \
  --from-literal=uri='postgresql://mlflow:SENHA@postgres.mlflow.svc:5432/mlflow'

kubectl --context mark-server -n mlflow create secret generic mlflow-s3-credentials \
  --from-literal=access-key-id='MINIO_ACCESS_KEY' \
  --from-literal=secret-access-key='MINIO_SECRET_KEY' \
  --from-literal=endpoint-url='http://minio.mlflow.svc:9000'
```

2. Instale com os values de produção:

```bash
VALUES_FILE=values-production.yaml ./instalar-mlflow.sh install
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
cp -R /tmp/mlflow-chart-dl/* /Users/dreis/devops/Gromit/MLFlow/chart/
```

## Troubleshooting

| Sintoma | Causa provável | Ação |
|---------|----------------|------|
| `connection refused` em `:6443` | API server do K8s parado | Subir o cluster no host `192.168.15.56` |
| Pod `Pending` | Sem StorageClass / PVC | `kubectl get sc`; ajuste `storage.storageClassName` |
| HTTP 403 no Ingress | Host não permitido | Defina `server.value_options.allowed_hosts` |
| `ImagePullBackOff` | Sem acesso ao ghcr.io | Espelhe a imagem ou configure `imagePullSecrets` |
