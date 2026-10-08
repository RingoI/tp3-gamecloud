# TP3 - GameCloud migra a AWS

Administración Avanzada de Redes y Servidores - UNNOBA - Actividad N°3: *Aplicaciones en la Nube*

Milton Ibarzabal

Ranking online de puntajes para los juegos Doom y Pac-Man de GameCloud, implementado como una arquitectura **serverless** sobre [MiniStack](https://github.com/ministackorg/ministack) (emulador local de AWS). Se usan las mismas herramientas (AWS CLI) que contra una cuenta real.

## Arquitectura

```
                   ┌────────────┐     ┌──────────────┐
Jugador ──────────►│ CloudFront │────►│  S3 (web)    │
   │               └────────────┘     └──────────────┘
   │
   │ GET /ranking   ┌──────────────┐    ┌──────────┐
   ├───────────────►│ API Gateway  │───►│ Lambda   │──────┐
   │                │ (HTTP API)   │    │ ranking  │      │
   │ POST /scores   │              │    └──────────┘      ▼
   └───────────────►│              │    ┌──────────┐  ┌──────────┐
                    └──────────────┘───►│ Lambda   │  │ DynamoDB │
                                        │ recibir  │  │ Puntajes │
                                        └────┬─────┘  └──────────┘
                                             ▼              ▲
                    ┌──────────┐      ┌──────────┐    ┌─────┴────┐
                    │   DLQ    │◄─────│   SQS    │───►│ Lambda   │
                    └──────────┘  3x  │ puntajes │    │ procesar │
                                      └──────────┘    └──────────┘
```

| Componente | Recurso | Detalle |
|---|---|---|
| Frontend | S3 `gamecloud-web` + CloudFront | Sitio estático (`index.html` + `config.js`) |
| API | API Gateway HTTP `gamecloud-api` | `GET /ranking`, `POST /scores`, CORS, throttling 100 req/s (ráfaga 200) |
| Lambda | `ranking` | Top 10 de cada juego; acepta `?juego=doom` |
| Lambda | `recibir_puntaje` | Valida el puntaje, lo encola en SQS y responde `202` (o `400`) |
| Lambda | `procesar_puntaje` | Lee la cola y guarda en DynamoDB solo si supera el mejor puntaje |
| Cola | SQS `puntajes` + `puntajes-dlq` | Visibility timeout 30 s; 3 intentos antes de pasar a la DLQ |
| Base | DynamoDB `Puntajes` | Clave `juego` (HASH) + `jugador` (RANGE), `PAY_PER_REQUEST` |
| Seguridad | IAM `gamecloud-lambda-role` | Política de mínimo privilegio |

## Estructura del repositorio

```
tp3-gamecloud/
├── README.md
├── docker-compose.yml        # MiniStack
├── iam/
│   ├── trust-lambda.json     # trust policy: permite a Lambda asumir el rol
│   └── politica-lambdas.json # permisos mínimos (tabla, cola, logs)
├── lambdas/
│   ├── ranking.py
│   ├── recibir_puntaje.py
│   └── procesar_puntaje.py
├── scripts/
│   ├── deploy.sh             # despliegue completo
│   ├── pruebas.sh            # pruebas de la arquitectura
│   ├── limpieza.sh           # elimina todos los recursos
│   └── evento-*.json         # eventos de prueba para lambda invoke
└── web/
    └── index.html
```

## Requisitos

- Docker y Docker Compose
- AWS CLI v2
- `bash`, `curl`, `zip` y `python3` (en Windows se recomienda WSL)

## Cómo reproducir la práctica

**1. Levantar MiniStack**

```bash
docker compose up -d
# equivalente a:
# docker run -d --name ministack -p 4566:4566 \
#   -v /var/run/docker.sock:/var/run/docker.sock ministackorg/ministack
```

**2. Credenciales ficticias y alias** (MiniStack no valida las credenciales)

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awsl='aws --endpoint-url=http://localhost:4566'
awsl s3 ls
```

**3. Desplegar toda la arquitectura**

```bash
./scripts/deploy.sh
```

Crea, en orden: bucket S3 y CloudFront, tabla DynamoDB, colas SQS, rol y política IAM, las tres funciones Lambda con su event source mapping, la API Gateway y el archivo `web/config.js` con la URL de la API.

**4. Abrir la web**

```
http://localhost:4566/gamecloud-web/index.html
```

> En MiniStack, CloudFront funciona solo a nivel API (la distribución se crea pero no sirve contenido), por eso el sitio se prueba desde la URL de S3.

**5. Probar la API**

```bash
API_ID=$(awsl apigatewayv2 get-apis --query "Items[?Name=='gamecloud-api'].ApiId" --output text)

# enviar un puntaje (responde 202)
curl -X POST http://$API_ID.execute-api.localhost:4566/scores \
  -H 'Content-Type: application/json' \
  -d '{"jugador":"ana","juego":"doom","puntaje":9800}'

# consultar el ranking
curl http://$API_ID.execute-api.localhost:4566/ranking
curl "http://$API_ID.execute-api.localhost:4566/ranking?juego=doom"
```

Si el nombre `*.execute-api.localhost` no resuelve en tu entorno, agregá a `curl` la opción `--resolve $API_ID.execute-api.localhost:4566:127.0.0.1`.

**6. Ejecutar las pruebas de la arquitectura**

```bash
./scripts/pruebas.sh
```

Cubre: puntajes válidos (202), juego inexistente (400), puntaje menor al mejor (el ranking no cambia), consultas del ranking, pico de 50 puntajes en paralelo, mensaje inválido que termina en la dead-letter queue y logs de `procesar_puntaje` en CloudWatch Logs. La prueba del mensaje inválido tarda un par de minutos (3 intentos con visibility timeout de 30 s).

**7. Limpiar**

```bash
./scripts/limpieza.sh
```

## Decisiones de diseño

- **Encolado de puntajes.** `POST /scores` no escribe en la base: valida, envía el mensaje a SQS y responde `202 Accepted`. La cola absorbe los picos de los torneos y desacopla la API de la base de datos.
- **Idempotencia.** `procesar_puntaje` escribe con la condición `attribute_not_exists(puntaje) OR puntaje < :p`. Si SQS entrega el mismo mensaje dos veces (entrega "al menos una vez"), la segunda escritura no supera el puntaje ya guardado y se ignora, por lo que el resultado final es el mismo.
- **Un único registro por jugador y juego.** La clave compuesta `(juego, jugador)` garantiza que un nuevo ítem con la misma clave reemplace al anterior, por lo que solo se conserva el mejor puntaje.
- **Dead-letter queue.** `procesar_puntaje` relanza la excepción ante un mensaje inválido; SQS lo reintenta y, tras 3 intentos fallidos (`maxReceiveCount = 3`), lo mueve a `puntajes-dlq`. El event source mapping usa `batch-size 1` para que un mensaje defectuoso no arrastre a los válidos.
- **Mínimo privilegio.** La política IAM permite solo `dynamodb:Query` y `dynamodb:PutItem` sobre la tabla `Puntajes`, las operaciones de SQS sobre la cola `puntajes` y la escritura de logs en `/aws/lambda/*`. No usa comodines en acciones de datos.
- **Validación en `recibir_puntaje`.** Se rechaza con `400` un cuerpo que no sea JSON, un jugador vacío, un juego fuera de `doom`/`pacman` y un puntaje que no sea un entero no negativo. Los juegos válidos se configuran con la variable de entorno `JUEGOS`.
- **Configuración por variables de entorno.** La URL de la cola y el nombre de la tabla se pasan a las funciones mediante variables de entorno (`scripts/env-lambda.json`, generado por `deploy.sh`).

## Nota sobre `web/index.html`

El `index.html` provisto por la cátedra no pudo obtenerse de forma aislada desde la PlataformaED (al descargarlo se obtenía la página completa de la plataforma). Se desarrolló un `index.html` equivalente que:

- lee la URL de la API desde `config.js` (`window.GAMECLOUD_API`),
- muestra el top 10 de Doom y Pac-Man con `GET /ranking`,
- permite cargar puntajes con `POST /scores`.

`web/config.js` se genera durante el despliegue (contiene el ID de la API) y por eso no se versiona.

## Entrega

La resolución de las actividades (capturas de los comandos, los recursos creados y los resultados de las pruebas) y las respuestas a las preguntas conceptuales se entregan en el archivo PDF por la PlataformaED.
