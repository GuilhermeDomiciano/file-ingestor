set -euo pipefail

export MSYS_NO_PATHCONV=1

LS="docker exec -i localstack awslocal"

log_tail() {
  echo
  echo "—— Últimos logs do LocalStack ——"
  docker logs --tail=200 localstack || true
  echo "——————————————————————————————"
}

echo "⏳ Esperando LocalStack responder ao CLI (s3 ls)..."
ok_cli=0
for i in {1..120}; do
  if $LS s3 ls >/dev/null 2>&1; then
    ok_cli=1
    break
  fi
  sleep 1
done
if [ "$ok_cli" -ne 1 ]; then
  echo "❌ LocalStack não respondeu ao CLI em 120s."
  log_tail
  exit 1
fi
echo "✅ CLI ok."

wait_lambda_active () {
  local fn="$1"
  echo "⏳ Aguardando Lambda '$fn' ficar Active..."
  for i in {1..120}; do
    state=$($LS lambda get-function-configuration --function-name "$fn" --query 'State' --output text 2>/dev/null || echo "Missing")
    echo "  - $fn: $state"
    if [ "$state" = "Active" ]; then
      echo "✅ $fn Active."
      return 0
    fi
    sleep 1
  done
  echo "❌ $fn não ficou Active em 120s."
  log_tail
  exit 1
}

wait_lambda_active ingestLambda
wait_lambda_active apiLambda

INGEST_ARN=$($LS lambda get-function --function-name ingestLambda --query 'Configuration.FunctionArn' --output text)

echo "⏳ Conferindo notificação do S3 → Lambda (ingestor-raw contém $INGEST_ARN)..."
ok_notif=0
for i in {1..60}; do
  conf=$($LS s3api get-bucket-notification-configuration --bucket ingestor-raw 2>/dev/null || echo "")
  if echo "$conf" | grep -q "$INGEST_ARN"; then
    ok_notif=1
    break
  fi
  sleep 1
done
if [ "$ok_notif" -ne 1 ]; then
  echo "❌ Notificação do S3 não encontrada com ARN da Lambda."
  echo "$conf"
  log_tail
  exit 1
fi
echo "✅ Notificação S3 configurada."

echo "🪣 Upload de teste (dispara ingestLambda)..."
printf 'Hello World!\n' | docker exec -i localstack awslocal s3 cp - s3://ingestor-raw/test.txt

echo "⏱ Aguardando processamento..."
sleep 4

echo "📦 Listando buckets:"
$LS s3 ls s3://ingestor-raw || true
$LS s3 ls s3://ingestor-processed || true

echo "🔍 Itens no DynamoDB (máx 10):"
$LS dynamodb scan --table-name files --max-items 10 || true

API_ID=$($LS apigateway get-rest-apis --query 'items[?name==`FileAPI`].id | [0]' --output text 2>/dev/null || echo "")
if [ -n "$API_ID" ] && [ "$API_ID" != "None" ]; then
  LIST_URL="http://localhost:4566/restapis/${API_ID}/dev/_user_request_/files"
  ITEM_URL="http://localhost:4566/restapis/${API_ID}/dev/_user_request_/files/test.txt"
  echo "🌐 GET /files  →  $LIST_URL"
  curl -s "$LIST_URL"; echo
  echo "🌐 GET /files/test.txt  →  $ITEM_URL"
  curl -s "$ITEM_URL"; echo
else
  echo "⚠️  API 'FileAPI' não encontrada."
  log_tail
fi

echo "✅ Fluxo concluído."
