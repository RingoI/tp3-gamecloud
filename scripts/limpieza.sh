#!/usr/bin/env bash
# Elimina todos los recursos creados por deploy.sh.
# Uso:  ./scripts/limpieza.sh
# Cada paso tolera errores para poder ejecutarse aunque falten recursos.
set -uo pipefail
cd "$(dirname "$0")/.."

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

echo "==> API Gateway"
for id in $(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text 2>/dev/null); do
  awsl apigatewayv2 delete-api --api-id "$id" && echo "    API $id eliminada"
done

echo "==> Event source mapping y funciones Lambda"
for uuid in $(awsl lambda list-event-source-mappings --function-name procesar_puntaje \
              --query "EventSourceMappings[].UUID" --output text 2>/dev/null); do
  awsl lambda delete-event-source-mapping --uuid "$uuid" > /dev/null && echo "    mapping $uuid eliminado"
done
for f in ranking recibir_puntaje procesar_puntaje; do
  awsl lambda delete-function --function-name "$f" && echo "    funcion $f eliminada"
done

echo "==> Colas SQS"
for q in puntajes puntajes-dlq; do
  url=$(awsl sqs get-queue-url --queue-name "$q" --query QueueUrl --output text 2>/dev/null) \
    && awsl sqs delete-queue --queue-url "$url" && echo "    cola $q eliminada"
done

echo "==> Tabla DynamoDB"
awsl dynamodb delete-table --table-name Puntajes > /dev/null && echo "    tabla Puntajes eliminada"

echo "==> IAM"
POLICY_ARN="arn:aws:iam::000000000000:policy/gamecloud-lambda-policy"
awsl iam detach-role-policy --role-name gamecloud-lambda-role --policy-arn "$POLICY_ARN"
awsl iam delete-policy --policy-arn "$POLICY_ARN" && echo "    politica eliminada"
awsl iam delete-role --role-name gamecloud-lambda-role && echo "    rol eliminado"

echo "==> CloudWatch Logs"
for g in ranking recibir_puntaje procesar_puntaje; do
  awsl logs delete-log-group --log-group-name "/aws/lambda/$g" 2>/dev/null
done

echo "==> CloudFront"
for id in $(awsl cloudfront list-distributions --query "DistributionList.Items[].Id" --output text 2>/dev/null); do
  etag=$(awsl cloudfront get-distribution-config --id "$id" --query ETag --output text 2>/dev/null)
  awsl cloudfront delete-distribution --id "$id" --if-match "$etag" 2>/dev/null \
    && echo "    distribucion $id eliminada" \
    || echo "    AVISO: no se pudo eliminar la distribucion $id (se perdera al reiniciar MiniStack)"
done

echo "==> Bucket S3"
awsl s3 rm s3://gamecloud-web --recursive > /dev/null
awsl s3 rb s3://gamecloud-web && echo "    bucket eliminado"

rm -f web/config.js scripts/env-lambda.json scripts/sqs-attrs.json /tmp/ranking.zip /tmp/recibir_puntaje.zip /tmp/procesar_puntaje.zip
echo
echo "Limpieza finalizada."
