import json
import os

import boto3
from botocore.exceptions import ClientError

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
JUEGOS = [j.strip() for j in os.environ.get("JUEGOS", "doom,pacman").split(",")]


def _parsear(cuerpo):
    try:
        datos = json.loads(cuerpo)
        jugador = datos["jugador"]
        juego = datos["juego"]
        puntaje = datos["puntaje"]
    except (ValueError, KeyError, TypeError) as e:
        raise ValueError(f"Mensaje inválido: {e}")
    if not isinstance(jugador, str) or not jugador or juego not in JUEGOS:
        raise ValueError("Jugador o juego inválido")
    if isinstance(puntaje, bool) or not isinstance(puntaje, int):
        raise ValueError("Puntaje inválido")
    return jugador, juego, puntaje


def handler(event, context):
    for registro in event["Records"]:
        try:
            jugador, juego, puntaje = _parsear(registro["body"])
        except ValueError as e:
            print(f"ERROR mensaje {registro.get('messageId')}: {e}")
            raise  # SQS reintenta y, tras 3 intentos, lo manda a la DLQ

        try:
            TABLE.put_item(
                Item={"juego": juego, "jugador": jugador, "puntaje": puntaje},
                ConditionExpression="attribute_not_exists(puntaje) OR puntaje < :p",
                ExpressionAttributeValues={":p": puntaje},
            )
            print(f"GUARDADO {jugador} en {juego}: {puntaje}")
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                print(f"IGNORADO {jugador} en {juego}: {puntaje} no supera el mejor puntaje")
            else:
                raise
    return {"procesados": len(event["Records"])}
