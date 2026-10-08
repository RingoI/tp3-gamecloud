#!/usr/bin/env bash
# Pruebas de la arquitectura GameCloud (etapa 6 del TP3).
# Uso:  ./scripts/pruebas.sh
# Requiere haber ejecutado antes ./scripts/deploy.sh
set -uo pipefail
cd "$(dirname "$0")/.."

export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
awsl() { aws --endpoint-url=http://localhost:4566 "$@"; }

API_ID=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text)
QUEUE_URL=$(awsl sqs get-queue-url --queue-name puntajes --query QueueUrl --output text)
DLQ_URL=$(awsl sqs get-queue-url --queue-name puntajes-dlq --query QueueUrl --output text)
BASE="http://$API_ID.execute-api.localhost:4566"
# --resolve evita problemas de DNS con *.execute-api.localhost dentro de WSL
CURL="curl --resolve $API_ID.execute-api.localhost:4566:127.0.0.1"

titulo() { echo; echo "=================== $* ==================="; }
estado_cola() {
  awsl sqs get-queue-attributes --queue-url "$QUEUE_URL" \
    --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible \
    --query Attributes --output json
}
post() {  # post <jugador> <juego> <puntaje>  -> imprime el codigo HTTP
  $CURL -s -o /dev/null -w "%{http_code}" -X POST "$BASE/scores" \
    -H 'Content-Type: application/json' \
    -d "{\"jugador\":\"$1\",\"juego\":\"$2\",\"puntaje\":$3}"
}

titulo "Prueba 0: funciones aisladas con lambda invoke"
for par in "recibir_puntaje:evento-recibir" "recibir_puntaje:evento-invalido" "procesar_puntaje:evento-sqs"; do
  fn="${par%%:*}"; ev="${par##*:}"
  echo "--- $fn con $ev.json"
  awsl lambda invoke --function-name "$fn" --cli-binary-format raw-in-base64-out \
    --payload "file://scripts/$ev.json" /tmp/out.json > /dev/null
  cat /tmp/out.json; echo
done
awsl lambda invoke --function-name ranking --cli-binary-format raw-in-base64-out \
  --payload '{}' /tmp/out.json > /dev/null
echo "--- ranking"; cat /tmp/out.json; echo

titulo "Prueba 1: al menos 5 puntajes validos (se espera 202)"
for d in "ana doom 9800" "beto pacman 500" "carla doom 7000" "dario pacman 12000" "eva doom 15000" "fede pacman 3000"; do
  set -- $d
  echo "$1 / $2 / $3 -> HTTP $(post "$1" "$2" "$3")"
done

titulo "Prueba 2: juego inexistente (se espera 400)"
$CURL -i -X POST "$BASE/scores" -H 'Content-Type: application/json' \
  -d '{"jugador":"ana","juego":"inexistente","puntaje":100}'
echo

titulo "Prueba 3: puntaje menor al mejor (el ranking no debe cambiar)"
sleep 5
echo "Ranking de doom ANTES:"
$CURL -s "$BASE/ranking?juego=doom" | python3 -m json.tool
echo "Enviando ana/doom/100 -> HTTP $(post ana doom 100)"
sleep 5
echo "Ranking de doom DESPUES:"
$CURL -s "$BASE/ranking?juego=doom" | python3 -m json.tool

titulo "Prueba 4: consulta del ranking"
echo "GET /ranking"
$CURL -s "$BASE/ranking" | python3 -m json.tool
echo "GET /ranking?juego=doom"
$CURL -s "$BASE/ranking?juego=doom" | python3 -m json.tool

titulo "Prueba 5: pico de 50 puntajes en paralelo"
# Se usa @@ como marcador de xargs para no pisar el % de %{http_code}
(seq 1 50 | xargs -P 50 -I@@ $CURL -s -o /dev/null -w "%{http_code} " -X POST "$BASE/scores" \
  -H 'Content-Type: application/json' \
  -d '{"jugador":"torneo@@","juego":"doom","puntaje":@@00}'; echo) &
PID=$!
echo "Estado de la cola DURANTE el pico:"
for i in 1 2 3 4 5; do estado_cola; sleep 1; done
wait "$PID"
sleep 10
echo "Estado de la cola una vez PROCESADA:"
estado_cola
echo "Puntajes 'torneo*' guardados en DynamoDB (se esperan 50):"
awsl dynamodb scan --table-name Puntajes --select COUNT \
  --filter-expression "begins_with(jugador, :p)" \
  --expression-attribute-values '{":p":{"S":"torneo"}}'

titulo "Prueba 6: mensaje invalido enviado directo a la cola -> DLQ"
awsl sqs send-message --queue-url "$QUEUE_URL" --message-body "esto no es json"
echo "Esperando que el mensaje llegue a la DLQ (hasta 3 minutos)..."
for i in $(seq 1 12); do
  N=$(awsl sqs get-queue-attributes --queue-url "$DLQ_URL" \
        --attribute-names ApproximateNumberOfMessages \
        --query Attributes.ApproximateNumberOfMessages --output text)
  echo "  [$((i * 15))s] mensajes en la DLQ: $N"
  [ "$N" != "0" ] && break
  sleep 15
done
awsl sqs receive-message --queue-url "$DLQ_URL"

titulo "Prueba 7: logs de procesar_puntaje en CloudWatch Logs"
awsl logs filter-log-events --log-group-name /aws/lambda/procesar_puntaje \
  --query "events[].message" --output text
echo
echo "Pruebas finalizadas."
