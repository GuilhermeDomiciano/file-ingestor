# File Ingestor (LocalStack)

Pipeline **local** que simula componentes AWS para ingerir arquivos e expor metadados via API.

**Fluxo:**  
1) Upload em **S3** (`ingestor-raw`) dispara **Lambda Ingest**;  
2) A Lambda lê metadados (`size`, `etag`, `contentType`), calcula **SHA-256**, cria item no **DynamoDB (files)** com `status=RAW`;  
3) Move o objeto para **ingestor-processed** e atualiza o item para `status=PROCESSED` + `processedAt`;  
4) **API Gateway + Lambda** expõe consultas: `GET /files` e `GET /files/{id}`.

---

## 🧱 Stack
- **LocalStack** (S3, DynamoDB, Lambda, API Gateway)
- **Python 3.11** nas Lambdas + **boto3**
- **Docker Compose**
- **AWS CLI local** via `awslocal` (executado *dentro* do container)

---

## 📁 Estrutura do repositório
```
.
├── docker-compose.yml
├── localstack-init/
│   └── 01-setup.sh         # cria buckets/tabela, empacota e registra lambdas, API e trigger S3
├── src/
│   ├── lambda_ingest/
│   │   └── handler.py
│   ├── lambda_api/
│   │   └── handler.py
│   └── utils/
│       └── checksum.py     # SHA-256
└── scripts/
    └── test_flow.sh        # fluxo end-to-end via docker exec
```

---

## 🚀 Subir (um comando)
```bash
docker compose up --build
```
> Aguarde ver **“✅ Setup concluído!”** nos logs do container `localstack`.

### Derrubar (um comando)
```bash
docker compose down -v
```

---

## 🧪 Teste end‑to‑end (Windows/Git Bash friendly)
> O script não depende de `awslocal` instalado no host; ele usa `docker exec`.

```bash
bash scripts/test_flow.sh
```
O script:
- aguarda o CLI do LocalStack responder,
- aguarda as duas Lambdas ficarem **Active**,
- valida a notificação do S3 → Lambda,
- faz o upload, lista buckets, lê o Dynamo e chama a API.

### Teste manual (alternativa rápida)
```bash
# evitar path conversion no Git Bash
export MSYS_NO_PATHCONV=1

# upload que dispara a ingestão
docker exec -i localstack awslocal s3 cp - s3://ingestor-raw/test.txt <<<'Hello World!'
sleep 4

# conferir buckets
docker exec -i localstack awslocal s3 ls s3://ingestor-raw
docker exec -i localstack awslocal s3 ls s3://ingestor-processed

# conferir Dynamo
docker exec -i localstack awslocal dynamodb scan --table-name files --max-items 10

# chamar API
API_ID=$(docker exec -i localstack awslocal apigateway get-rest-apis --query 'items[?name==`FileAPI`].id | [0]' --output text)
curl -s "http://localhost:4566/restapis/${API_ID}/dev/_user_request_/files"
curl -s "http://localhost:4566/restapis/${API_ID}/dev/_user_request_/files/test.txt"
```

---

## 🌐 API
### `GET /files`
- **Query params** (opcionais):  
  `status=RAW|PROCESSED`, `from=YYYY-MM-DDTHH:MM:SS`, `to=YYYY-MM-DDTHH:MM:SS`  
- **Resposta**: JSON com até 100 itens filtrados.

### `GET /files/{id}`
- `id` corresponde ao `key` do arquivo (ex.: `test.txt` → `pk = file#test.txt`).

---

## 🗄️ Tabela DynamoDB: `files`
| Campo        | Tipo   | Exemplo/Descrição                                   |
|--------------|--------|------------------------------------------------------|
| `pk`         | S      | `file#test.txt` (PK)                                 |
| `bucket`     | S      | `ingestor-raw`                                       |
| `key`        | S      | `test.txt`                                           |
| `size`       | N      | `13`                                                 |
| `etag`       | S      | Hash do S3                                           |
| `status`     | S      | `RAW` → `PROCESSED`                                  |
| `processedAt`| S      | `2025-10-22T23:05:29.909635` (ISO)                   |
| `contentType`| S      | `binary/octet-stream`                                |
| `checksum`   | S      | SHA‑256 calculado na Lambda                          |

---

## 🧠 Decisões
- **SHA‑256** para integridade independente do ETag do S3.  
- **PK** como `file#{key}` facilita `GET /files/{id}`.  
- **Move** como *copy+delete* em S3 (idempotente e simples).  
- **Filtros da API** aplicados após `scan` (adequado ao cenário local).  
- **Robustez de init**: aguardar Lambdas `Active` antes de configurar notificação S3.

---

## 🐞 Troubleshooting
- **Não dispara a Lambda**: confirme que as Lambdas estão `Active` e que a notificação do S3 contém o ARN da `ingestLambda`  
  ```bash
  docker exec -it localstack awslocal s3api get-bucket-notification-configuration --bucket ingestor-raw
  ```
- **Windows/Git Bash**: use `export MSYS_NO_PATHCONV=1` antes de `docker exec` com heredoc/`<< <`.
- **Nada acontece após upload**: confira logs:
  ```bash
  docker logs --tail=200 localstack
  ```
