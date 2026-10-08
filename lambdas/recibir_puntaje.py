import base64
import json
import os

import boto3

SQS = boto3.client("sqs")
QUEUE_URL = os.environ["QUEUE_URL"]
JUEGOS = [j.strip() for j in os.environ.get("JUEGOS", "doom,pacman").split(",")]


def _respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(cuerpo),
    }


def handler(event, context):
    crudo = event.get("body") or ""
    if event.get("isBase64Encoded"):
        crudo = base64.b64decode(crudo).decode("utf-8")

    try:
        datos = json.loads(crudo)
    except (ValueError, TypeError):
        return _respuesta(400, {"error": "El cuerpo no es un JSON válido"})

    if not isinstance(datos, dict):
        return _respuesta(400, {"error": "El cuerpo debe ser un objeto JSON"})

    jugador = datos.get("jugador")
    juego = datos.get("juego")
    puntaje = datos.get("puntaje")

    if not isinstance(jugador, str) or not jugador.strip() or len(jugador) > 50:
        return _respuesta(400, {"error": "Jugador inválido"})
    if juego not in JUEGOS:
        return _respuesta(400, {"error": "Juego inexistente"})
    if isinstance(puntaje, bool) or not isinstance(puntaje, int) or puntaje < 0:
        return _respuesta(400, {"error": "El puntaje debe ser un entero no negativo"})

    mensaje = {"jugador": jugador.strip(), "juego": juego, "puntaje": puntaje}
    SQS.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps(mensaje))
    return _respuesta(202, {"mensaje": "Puntaje recibido"})
