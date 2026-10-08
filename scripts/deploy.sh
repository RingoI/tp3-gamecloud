#!/usr/bin/env bash
# Despliegue completo de la arquitectura GameCloud sobre MiniStack.
# Uso:  ./scripts/deploy.sh
# Pensado para un MiniStack limpio (o despues de ejecutar ./scripts/limpieza.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

echo "==> 0. Verificando conexion con MiniStack"
awsl s3 ls > /dev/null

# ---------------------------------------------------------------
echo "==> 1. Frontend: bucket S3 con static website hosting"
awsl s3 mb s3://gamecloud-web
awsl s3 website s3://gamecloud-web --index-document index.html
awsl s3 cp web/index.html s3://gamecloud-web/index.html --content-type text/html

echo "==> 1b. CloudFront (en MiniStack solo existe a nivel API)"
awsl cloudfront create-distribution \
  --origin-domain-name gamecloud-web.s3.amazonaws.com \
  --default-root-object index.html > /dev/null \
  || echo "AVISO: no se pudo crear la distribucion de CloudFront (no es critico)"

# ---------------------------------------------------------------
echo "==> 2. DynamoDB: tabla Puntajes"
awsl dynamodb create-table \
  --table-name Puntajes \
  --attribute-definitions AttributeName=juego,AttributeType=S AttributeName=jugador,AttributeType=S \
  --key-schema AttributeName=juego,KeyType=HASH AttributeName=jugador,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST > /dev/null
TABLE_ARN=$(awsl dynamodb describe-table --table-name Puntajes --query Table.TableArn --output text)

# ---------------------------------------------------------------
echo "==> 3. SQS: cola puntajes y dead-letter queue"
awsl sqs create-queue --queue-name puntajes-dlq > /dev/null
DLQ_URL=$(awsl sqs get-queue-url --queue-name puntajes-dlq --query QueueUrl --output text)
DLQ_ARN=$(awsl sqs get-queue-attributes --queue-url "$DLQ_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)

cat > scripts/sqs-attrs.json << EOF
{
  "VisibilityTimeout": "30",
  "RedrivePolicy": "{\"deadLetterTargetArn\":\"$DLQ_ARN\",\"maxReceiveCount\":\"3\"}"
}
EOF
awsl sqs create-queue --queue-name puntajes --attributes file://scripts/sqs-attrs.json > /dev/null
QUEUE_URL=$(awsl sqs get-queue-url --queue-name puntajes --query QueueUrl --output text)
QUEUE_ARN=$(awsl sqs get-queue-attributes --queue-url "$QUEUE_URL" --attribute-names QueueArn --query Attributes.QueueArn --output text)

# ---------------------------------------------------------------
echo "==> 4. IAM: rol y politica de minimo privilegio"
awsl iam create-role --role-name gamecloud-lambda-role \
  --assume-role-policy-document file://iam/trust-lambda.json > /dev/null

cat > iam/politica-lambdas.json << EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "DynamoDBPuntajes",
      "Effect": "Allow",
      "Action": ["dynamodb:Query", "dynamodb:PutItem"],
      "Resource": "$TABLE_ARN"
    },
    {
      "Sid": "SQSPuntajes",
      "Effect": "Allow",
      "Action": ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"],
      "Resource": "$QUEUE_ARN"
    },
    {
      "Sid": "LogsLambda",
      "Effect": "Allow",
      "Action": ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"],
      "Resource": "arn:aws:logs:us-east-1:*:log-group:/aws/lambda/*"
    }
  ]
}
EOF
POLICY_ARN=$(awsl iam create-policy --policy-name gamecloud-lambda-policy \
  --policy-document file://iam/politica-lambdas.json --query Policy.Arn --output text)
awsl iam attach-role-policy --role-name gamecloud-lambda-role --policy-arn "$POLICY_ARN"
ROLE_ARN=$(awsl iam get-role --role-name gamecloud-lambda-role --query Role.Arn --output text)

# ---------------------------------------------------------------
echo "==> 5. Lambda: ranking, recibir_puntaje, procesar_puntaje"
cat > scripts/env-lambda.json << EOF
{"Variables": {"TABLE_NAME": "Puntajes", "QUEUE_URL": "$QUEUE_URL", "JUEGOS": "doom,pacman"}}
EOF

for f in ranking recibir_puntaje procesar_puntaje; do
  zip -j -q "/tmp/$f.zip" "lambdas/$f.py"
  awsl lambda create-function \
    --function-name "$f" --runtime python3.12 --role "$ROLE_ARN" \
    --handler "$f.handler" --zip-file "fileb:///tmp/$f.zip" \
    --timeout 10 --environment file://scripts/env-lambda.json > /dev/null
  echo "    funcion $f creada"
  sleep 3   # MiniStack necesita unos segundos entre creaciones
done

awsl lambda create-event-source-mapping \
  --function-name procesar_puntaje --event-source-arn "$QUEUE_ARN" --batch-size 1 > /dev/null

# ---------------------------------------------------------------
echo "==> 6. API Gateway: gamecloud-api"
API_ID=$(awsl apigatewayv2 create-api --name gamecloud-api --protocol-type HTTP \
  --cors-configuration '{"AllowOrigins":["*"],"AllowMethods":["GET","POST","OPTIONS"],"AllowHeaders":["content-type"]}' \
  --query ApiId --output text)

RANKING_ARN=$(awsl lambda get-function --function-name ranking --query Configuration.FunctionArn --output text)
RECIBIR_ARN=$(awsl lambda get-function --function-name recibir_puntaje --query Configuration.FunctionArn --output text)

INT_RANKING=$(awsl apigatewayv2 create-integration --api-id "$API_ID" --integration-type AWS_PROXY \
  --integration-uri "$RANKING_ARN" --payload-format-version 2.0 --query IntegrationId --output text)
INT_RECIBIR=$(awsl apigatewayv2 create-integration --api-id "$API_ID" --integration-type AWS_PROXY \
  --integration-uri "$RECIBIR_ARN" --payload-format-version 2.0 --query IntegrationId --output text)

awsl apigatewayv2 create-route --api-id "$API_ID" --route-key "GET /ranking" --target "integrations/$INT_RANKING" > /dev/null
awsl apigatewayv2 create-route --api-id "$API_ID" --route-key "POST /scores" --target "integrations/$INT_RECIBIR" > /dev/null

awsl lambda add-permission --function-name ranking --statement-id apigw-ranking \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:000000000000:$API_ID/*/*/ranking" > /dev/null
awsl lambda add-permission --function-name recibir_puntaje --statement-id apigw-scores \
  --action lambda:InvokeFunction --principal apigateway.amazonaws.com \
  --source-arn "arn:aws:execute-api:us-east-1:000000000000:$API_ID/*/*/scores" > /dev/null

awsl apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' --auto-deploy \
  --default-route-settings ThrottlingBurstLimit=200,ThrottlingRateLimit=100 > /dev/null

# ---------------------------------------------------------------
echo "==> 7. config.js con la URL de la API"
echo "window.GAMECLOUD_API = \"http://$API_ID.execute-api.localhost:4566\";" > web/config.js
awsl s3 cp web/config.js s3://gamecloud-web/config.js --content-type application/javascript

echo
echo "Despliegue completo."
echo "  API_ID : $API_ID"
echo "  Web    : http://localhost:4566/gamecloud-web/index.html"
echo "  API    : http://$API_ID.execute-api.localhost:4566/ranking"
