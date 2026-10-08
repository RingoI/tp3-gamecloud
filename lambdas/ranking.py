import json
import os

import boto3
from boto3.dynamodb.conditions import Key

TABLE = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
JUEGOS = [j.strip() for j in os.environ.get("JUEGOS", "doom,pacman").split(",")]


def _respuesta(codigo, cuerpo):
    return {
        "statusCode": codigo,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(cuerpo),
    }


def _top10(juego):
    items = []
    kwargs = {"KeyConditionExpression": Key("juego").eq(juego)}
    while True:
        r = TABLE.query(**kwargs)
        items.extend(r["Items"])
        if "LastEvaluatedKey" not in r:
            break
        kwargs["ExclusiveStartKey"] = r["LastEvaluatedKey"]
    items.sort(key=lambda i: i["puntaje"], reverse=True)
    return [{"jugador": i["jugador"], "puntaje": int(i["puntaje"])} for i in items[:10]]


def handler(event, context):
    params = event.get("queryStringParameters") or {}
    juego = params.get("juego")
    if juego:
        if juego not in JUEGOS:
            return _respuesta(400, {"error": "Juego inexistente"})
        return _respuesta(200, {juego: _top10(juego)})
    return _respuesta(200, {j: _top10(j) for j in JUEGOS})
