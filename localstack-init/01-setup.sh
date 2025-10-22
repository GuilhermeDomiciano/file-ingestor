set -euo pipefail

echo "🚀 Criando buckets..."
awslocal s3 mb s3://ingestor-raw || true
awslocal s3 mb s3://ingestor-processed || true

echo "🧱 Criando tabela DynamoDB..."
if ! awslocal dynamodb describe-table --table-name files >/dev/null 2>&1; then
  awslocal dynamodb create-table \
    --table-name files \
    --attribute-definitions AttributeName=pk,AttributeType=S \
    --key-schema AttributeName=pk,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST
fi

echo "📦 Empacotando lambdas (com utils/)..."
python3 - <<'PY'
import os, zipfile

def pack(files_map, zip_path):
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as z:
        for arc, real in files_map.items():
            z.write(real, arc)

os.makedirs('/tmp/pkg', exist_ok=True)

# ingest: inclui utils/
ing_files = {'handler.py': '/app/src/lambda_ingest/handler.py'}
for root, _, files in os.walk('/app/src/utils'):
    for f in files:
        real = os.path.join(root, f)
        arc = os.path.relpath(real, '/app/src')  # ex: utils/checksum.py
        ing_files[arc] = real
pack(ing_files, '/tmp/lambda_ingest.zip')

# api
api_files = {'handler.py': '/app/src/lambda_api/handler.py'}
pack(api_files, '/tmp/lambda_api.zip')
PY

echo "⚙️ Criando Lambdas (se necessário)..."
if ! awslocal lambda get-function --function-name ingestLambda >/dev/null 2>&1; then
  awslocal lambda create-function \
    --function-name ingestLambda \
    --runtime python3.11 \
    --handler handler.lambda_handler \
    --zip-file fileb:///tmp/lambda_ingest.zip \
    --role arn:aws:iam::000000000000:role/lambda-role
fi

if ! awslocal lambda get-function --function-name apiLambda >/dev/null 2>&1; then
  awslocal lambda create-function \
    --function-name apiLambda \
    --runtime python3.11 \
    --handler handler.lambda_handler \
    --zip-file fileb:///tmp/lambda_api.zip \
    --role arn:aws:iam::000000000000:role/lambda-role
fi

wait_lambda_active () {
  local fn="$1"
  echo "⏳ Aguardando Lambda '$fn' ficar Active..."
  for i in {1..40}; do
    state=$(awslocal lambda get-function-configuration --function-name "$fn" --query 'State' --output text 2>/dev/null || echo "Pending")
    echo "  - $fn: $state"
    if [ "$state" = "Active" ]; then
      return 0
    fi
    sleep 1
  done
  echo "⚠️  $fn ainda não ficou Active; seguindo assim mesmo."
}

wait_lambda_active ingestLambda
wait_lambda_active apiLambda

INGEST_ARN=$(awslocal lambda get-function --function-name ingestLambda --query 'Configuration.FunctionArn' --output text)
API_ARN=$(awslocal lambda get-function --function-name apiLambda --query 'Configuration.FunctionArn' --output text)

echo "🔗 Permissão S3 → Lambda (id único p/ evitar conflito)..."
SID="s3invoke-$(date +%s)"
awslocal lambda add-permission \
  --function-name ingestLambda \
  --statement-id "$SID" \
  --action lambda:InvokeFunction \
  --principal s3.amazonaws.com \
  --source-arn arn:aws:s3:::ingestor-raw || true

echo "🔔 Configurando notificação do S3 → Lambda..."
awslocal s3api put-bucket-notification-configuration \
  --bucket ingestor-raw \
  --notification-configuration "{
    \"LambdaFunctionConfigurations\": [{
      \"LambdaFunctionArn\": \"$INGEST_ARN\",
      \"Events\": [\"s3:ObjectCreated:*\"] 
    }]
  }"

echo "🌐 Criando API Gateway (GET /files e GET /files/{id})..."
rest_api_id=$(awslocal apigateway create-rest-api --name FileAPI --query 'id' --output text)
parent_id=$(awslocal apigateway get-resources --rest-api-id "$rest_api_id" --query 'items[0].id' --output text)
files_res=$(awslocal apigateway create-resource --rest-api-id "$rest_api_id" --parent-id "$parent_id" --path-part "files" --query 'id' --output text)
id_res=$(awslocal apigateway create-resource --rest-api-id "$rest_api_id" --parent-id "$files_res" --path-part "{id}" --query 'id' --output text)

awslocal apigateway put-method \
  --rest-api-id $rest_api_id --resource-id $files_res \
  --http-method GET --authorization-type "NONE"
awslocal apigateway put-integration \
  --rest-api-id $rest_api_id --resource-id $files_res \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/$API_ARN/invocations

awslocal apigateway put-method \
  --rest-api-id $rest_api_id --resource-id $id_res \
  --http-method GET --authorization-type "NONE"
awslocal apigateway put-integration \
  --rest-api-id $rest_api_id --resource-id $id_res \
  --http-method GET \
  --type AWS_PROXY \
  --integration-http-method POST \
  --uri arn:aws:apigateway:us-east-1:lambda:path/2015-03-31/functions/$API_ARN/invocations

awslocal lambda add-permission \
  --function-name apiLambda \
  --statement-id apigwinvoke-$(date +%s) \
  --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com || true

awslocal apigateway create-deployment --rest-api-id $rest_api_id --stage-name dev

echo "✅ Setup concluído!"

awslocal apigateway create-deployment --rest-api-id $rest_api_id --stage-name dev

touch /tmp/ingestor_init.ok

echo "✅ Setup concluído!"