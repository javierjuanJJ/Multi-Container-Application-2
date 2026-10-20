# Multi-Container Application

Aplicación de lista de tareas desplegada con **Docker Compose**, provisionada con
**Terraform + Ansible**, publicada con un pipeline de **GitHub Actions** y
desplegada con estrategia **blue-green** (cero downtime, rollback inmediato).

![requisitos](https://img.shields.io/badge/requisitos-3%20%2B%20bonus-2496ed)

---

## Índice

- [Qué hay en el repo](#qué-hay-en-el-repo)
- [La API](#la-api)
- [Requisito 1 — Dockerizar la API](#requisito-1--dockerizar-la-api)
  - [Probando el CRUD](#probando-el-crud)
  - [Persistencia de datos](#persistencia-de-datos)
  - [Perfil de desarrollo con nodemon](#perfil-de-desarrollo-con-nodemon)
- [Requisito 2 — Servidor remoto con Terraform y Ansible](#requisito-2--servidor-remoto-con-terraform-y-ansible)
  - [Terraform](#terraform)
  - [Ansible](#ansible)
- [Requisito 3 — Pipeline de CI/CD](#requisito-3--pipeline-de-cicd)
  - [`ci.yml` — integración continua](#ciyml--integración-continua)
  - [`cd.yml` — entrega continua](#cdyml--entrega-continua)
- [Bonus — Reverse proxy con Nginx](#bonus--reverse-proxy-con-nginx)
- [Sesión — Blue-Green Deployment](#sesión--blue-green-deployment)
  - [Cómo funciona](#cómo-funciona)
  - [Los comandos](#los-comandos)
  - [Desplegar una nueva versión](#desplegar-una-nueva-versión)
  - [Rollback en un comando](#rollback-en-un-comando)
  - [Probar blue-green en local](#probar-blue-green-en-local)
  - [Qué pasa si algo falla](#qué-pasa-si-algo-falla)
- [Bonus — Monitoreo del despliegue](#bonus--monitoreo-del-despliegue)
  - [Prometheus + blackbox + cadvisor](#prometheus--blackbox--cadvisor)
  - [Alertas](#alertas)
  - [Watchdog liviano](#watchdog-liviano)
- [Seguridad](#seguridad)
- [Limpieza](#limpieza)

---

## Qué hay en el repo

```
.
├── api/                          # API de tareas (Node.js + Express + Mongoose)
│   ├── Dockerfile                # etapas deps / dev / runner
│   ├── .dockerignore
│   ├── package.json
│   └── src/
│       ├── index.js              # arranque, apagado ordenado, reconnect
│       ├── app.js                # rutas y middleware
│       ├── config.js             # variables de entorno tipadas
│       ├── db.js                 # conexión a MongoDB
│       ├── models/todo.model.js  # schema de Mongoose
│       └── routes/todos.routes.js
├── docker-compose.yml            # REQ 1: MongoDB + API en :3000
├── docker-compose.prod.yml       # REQ 2/3: MongoDB + 2 slots de API + Nginx en :80/:443
├── docker-compose.monitoring.yml # bonus: Prometheus + blackbox-exporter + cadvisor
├── nginx/
│   ├── conf.d/default.conf       # bonus: reverse proxy con upstream dinámico
│   └── upstream/active.conf      # blue-green: ESTADO, color que recibe tráfico
├── scripts/
│   ├── blue-green.sh             # blue-green: deploy / switch / rollback / status
│   └── monitor.sh                # blue-green: watchdog liviano del despliegue
├── monitoring/                   # bonus: configuración de Prometheus
│   ├── prometheus.yml            #   sondas HTTP contra cada color y el proxy
│   ├── alerts.yml                #   alertas del despliegue blue-green
│   └── blackbox.yml              #   módulo de sondeo http_2xx
├── terraform/                    # REQ 2: Droplet + Cloud Firewall + DNS
├── ansible/                      # REQ 2: rol docker + rol app (despliegue blue-green)
│   ├── site.yml                  # endurecimiento base del Droplet
│   ├── todos.yml                 # instala Docker y despliega el stack
│   └── roles/{docker,app}/
├── .github/workflows/
│   ├── ci.yml                    # REQ 3: smoke test del CRUD en cada push
│   └── cd.yml                    # REQ 3: publica la imagen y despliega (blue-green)
├── .env.example                  # variables para desarrollo
└── .env.production.example       # variables para el servidor
```

---

## La API

API REST **sin autenticación** para gestionar una lista de tareas. Cada documento
guarda `task`, `completed` y las marcas de tiempo `createdAt` / `updatedAt`.

| Método | Ruta          | Descripción                          | Respuesta                                |
|--------|---------------|--------------------------------------|------------------------------------------|
| `GET`    | `/todos`      | Obtiene todas las tareas             | `200` + array                             |
| `POST`   | `/todos`      | Crea una tarea                       | `201` + la tarea creada                  |
| `GET`    | `/todos/:id`  | Obtiene una tarea por id              | `200` + la tarea, `404` si no existe     |
| `PUT`    | `/todos/:id`  | Actualiza una tarea por id            | `200` + la tarea, `404` si no existe     |
| `DELETE` | `/todos/:id`  | Elimina una tarea por id              | `200` + la tarea eliminada, `404`         |
| `GET`    | `/health`     | Estado de la API y de MongoDB         | `200` si la base responde, `503` si no    |

Códigos de error que devuelve la API:

- `400` — id que no es un ObjectId válido, o cuerpo que no cumple el schema
  (`task` obligatorio, máximo 200 caracteres) o JSON mal formado.
- `404` — el id es válido pero no existe, o la ruta no existe.
- `500` — error inesperado (el detalle nunca sale en `NODE_ENV=production`).

`PUT` es una actualización parcial: solo toca los campos que vienen en el cuerpo.
Enviar `{ "completed": true }` no borra el `task`.

### Variables de entorno

| Variable           | Por defecto                     | Para qué                                        |
|--------------------|---------------------------------|-------------------------------------------------|
| `PORT`             | `3000`                          | Puerto de escucha                                |
| `MONGO_URI`        | `mongodb://localhost:27017/todos` | Cadena de conexión a MongoDB                   |
| `NODE_ENV`         | `development`                   | `production` silencia los logs de error internos |
| `SHUTDOWN_TIMEOUT_MS` | `10000`                      | Margen antes de forzar la salida en `SIGTERM`    |

---

## Requisito 1 — Dockerizar la API

```bash
cp .env.example .env          # opcional: los valores por defecto ya funcionan
docker compose up -d --build --wait
```

Con estolevantan dos contenedores: la API en <http://localhost:3000> y MongoDB.

```bash
docker compose ps             # ambos en healthy
curl http://localhost:3000/health
# {"status":"ok","uptime":3,"database":{"status":"connected","name":"todos"}}
```

### Probando el CRUD

```bash
# Crear
curl -X POST http://localhost:3000/todos \
  -H 'Content-Type: application/json' \
  -d '{"task":"Comprar pan","completed":false}'

# Listar
curl http://localhost:3000/todos

# Leer uno
curl http://localhost:3000/todos/<id>

# Actualizar
curl -X PUT http://localhost:3000/todos/<id> \
  -H 'Content-Type: application/json' \
  -d '{"completed":true}'

# Borrar
curl -X DELETE http://localhost:3000/todos/<id>
```

### Decisiones de diseño del `docker-compose.yml`

- **`depends_on` con `condition: service_healthy`.** La API no arranca hasta que
  MongoDB responde a un ping. Sin esto, el arranque simultáneo falla con
  `ECONNREFUSED` y hay que reintentar a mano.
- **`restart: true` en la dependencia.** Si MongoDB se reinicia, Compose reinicia
  también la API, que se queda con una conexión muerta.
- **Dos redes.** `backend` es `internal: true` (sin salida a internet): MongoDB
  solo habla con la API. `frontend` es la que usará el reverse proxy.
- **Volumen con nombre global.** El volumen se llama `todos-mongo-data` y no
  `todos_mongo-data`, así los datos sobreviven aunque cambie el nombre del
  proyecto o alternes entre el compose de desarrollo y el de producción.
- **Healthcheck sin dependencias.** El de la API usa `fetch` de Node, que ya está
  en la imagen: no hace falta instalar `curl` ni `wget` en el contenedor.

### Persistencia de datos

Los documentos se guardan en el volumen `todos-mongo-data` montado en `/data/db`:

```bash
docker compose stop && docker compose start   # los datos siguen ahi
docker compose down && docker compose up -d   # tambien: down no borra volumenes
docker compose down -v                        # esto SI borra los datos
```

### Perfil de desarrollo con nodemon

```bash
docker compose --profile dev up -d api-dev   # API con recarga en caliente en :3001
```

El servicio `api-dev` usa la etapa `dev` del Dockerfile (dependencias completas +
`nodemon`) y monta `./api/src` desde el host. Guarda un fichero en `api/src/` y
la API se reinicia sola, sin reconstruir la imagen.

---

## Requisito 2 — Servidor remoto con Terraform y Ansible

Orden de ejecución: **Terraform crea el Droplet → Ansible lo prepara →
GitHub Actions despliega el código.**

### Terraform

Crea el Droplet en DigitalOcean, un Cloud Firewall que solo deja entrar por SSH,
80 y 443, y —si defines `domain_name`— el registro DNS del bonus.

```bash
export DIGITALOCEAN_TOKEN="dop_v1_XXX..."
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
$EDITOR terraform/terraform.tfvars          # pon aqui do_token y los parametros

terraform -chdir=terraform init
terraform -chdir=terraform apply
```

Guarda las salidas, te hacen falta para el siguiente paso:

```bash
terraform -chdir=terraform output ansible_inventory_host
terraform -chdir=terraform output -raw ipv4_address
```

> DigitalOcean cobra por Droplet activo. Al terminar la práctica ejecuta
> `terraform -chdir=terraform destroy`.

### Ansible

Dos roles, en este orden:

- **`docker`** — añade el repositorio oficial de Docker, instala `docker-ce` y el
  plugin `compose`, configura `/etc/docker/daemon.json` (rotación de logs y
  `live-restore`) y crea el usuario `deploy` dentro del grupo `docker`.
- **`app`** — copia al servidor `docker-compose.prod.yml`, la configuración de
  nginx y el script `blue-green.sh`, genera el `.env.production` en modo `0600`
  y deja que el propio script despliegue: la imagen nueva arranca en el color
  inactivo, espera a su healthcheck y solo entonces se conmuta el tráfico.

```bash
# 1) Endurecer el Droplet (usuario admin, SSH sin contraseña, ufw)
ansible-playbook site.yml

# 2) Instalar Docker y desplegar el stack
ansible-vault encrypt_string 'una-contrasena-larga-y-aleatoria' --name 'app_mongo_password'
ansible-playbook todos.yml --ask-vault-pass -e app_image=MI_USUARIO_DOCKERHUB/todos-api:latest
```

`todos.yml` delega el despliegue en `blue-green.sh`, así que por la vía de
Ansible también hay cero downtime y rollback inmediato. MongoDB no se recrea en
cada despliegue, así que el volumen sobrevive intacto.

Detalle importante: el rol **no** copia `nginx/upstream/active.conf`. Ese
fichero es el estado del despliegue en el servidor (qué color recibe tráfico);
subirlo desde el repositorio pondría el tráfico en un color que puede ni siquiera
estar desplegado. El propio script lo crea si no existe.

Variables del rol (`ansible/roles/app/defaults/main.yml`):

| Variable              | Por defecto | Descripción                                    |
|-----------------------|-------------|------------------------------------------------|
| `app_stop_previous`   | `false`     | Parar el color anterior al conmutar (ahorra RAM, pierde rollback inmediato) |
| `app_wait_timeout`    | `240`       | Segundos de espera del healthcheck del color nuevo |

### ¿Por qué Nginx corre en un contenedor y no instalado en el host?

Porque el bonus pide el proxy "usando docker-compose". Instalarlo en el host
competiría por el puerto 80 con el contenedor y además dejaría dos fuentes de
configuración. En `ansible/site.yml` se quitó nginx del host a propósito.

---

## Requisito 3 — Pipeline de CI/CD

Dos workflows independientes. `ci.yml` **siempre** corre; `cd.yml` solo despliega
si `ci.yml` pasó.

### `ci.yml` — integración continua

En cada push a `main` y en cada PR:

1. Levanta el stack real de `docker-compose.yml` con `--wait`.
2. Recorre el CRUD completo contra `http://localhost:3000`, incluido el `404`
   tras el borrado.
3. **Comprueba la persistencia:** crea una tarea, hace `docker compose down`,
   vuelve a levantar los contenedores y verifica que la tarea sigue ahí.
4. Publica los logs de los contenedores si algo falla y destruye el stack siempre.

No necesita secrets: MongoDB corre con las credenciales por defecto.

### `cd.yml` — entrega continua

En cada push a `main` (o a mano desde *Actions → CD → Run workflow*):

1. **build** — construye la imagen con Buildx y la publica en Docker Hub con las
   etiquetas `latest` y `sha-<corto>` (más metadatos OCI). Despliega la etiqueta
   del commit, que es inmutable: si el runner se corta a mitad, el siguiente
   despliegue sigue siendo el mismo artefacto.
2. **deploy** — por SSH nativo (sin acciones de terceros) sube por `rsync` los
   ficheros de compose, nginx, el script `blue-green.sh` y el `.env.production`;
   genera las credenciales de Docker Hub en el runner y las copia al servidor; y
   ejecuta `blue-green.sh deploy <imagen>`. La imagen nueva arranca en el color
   inactivo, se espera a su healthcheck y **solo después** se conmuta el tráfico.
3. **smoke-test** — comprueba `/health` y el CRUD completo contra el servidor ya
   desplegado, entrando por el reverse proxy (es decir, contra el color nuevo).

Detalle importante: `ssh host bash -s` **no reenvía el entorno local**, así que el
token de Docker Hub viaja dentro de un `config.json` generado con `docker login`
en el runner y copiado por `rsync`, nunca en la línea de comandos. El servidor lo
borra al terminar el despliegue.

`cd.yml` también admite ejecución manual con la casilla **rollback** marcada
(*Actions → CD → Run workflow*): en vez de desplegar, ejecuta
`blue-green.sh rollback` en el servidor, devuelve el tráfico al color anterior y
pasa por el mismo smoke test. Como el color anterior sigue desplegado y sano, no
hay rebuild ni pull.

#### Secrets y variables

*Settings → Secrets and variables → Actions.*

| Secret               | Obligatorio | Descripción                                       |
|----------------------|-------------|---------------------------------------------------|
| `DOCKERHUB_USERNAME` | sí          | Usuario de Docker Hub                             |
| `DOCKERHUB_TOKEN`    | sí          | Access token de Docker Hub (no la contraseña)    |
| `SERVER_HOST`        | sí          | IP pública del Droplet                            |
| `SERVER_SSH_KEY`     | sí          | Clave privada SSH con acceso al Droplet           |
| `MONGO_ROOT_PASSWORD`| sí          | Contraseña de MongoDB en producción               |
| `SERVER_HOST_KEY`    | no          | Host key del Droplet (si no, se usa `ssh-keyscan`) |

| Variable               | Por defecto | Descripción                        |
|------------------------|-------------|------------------------------------|
| `SERVER_USER`          | `deploy`    | Usuario SSH en el servidor         |
| `MONGO_ROOT_USERNAME`  | `root`      | Usuario de MongoDB                 |

> `ssh-keyscan` no autentica nada y es vulnerable a MITM. Para un despliegue
> serio guarda la huella real del Droplet en `SERVER_HOST_KEY`:
> `ssh-keyscan -t ed25519 <IP>` y compara con `doctl compute ssh list`.

Si el repositorio es privado, añade `packages: write` a `permissions` y usa
`${{ secrets.GITHUB_TOKEN }}` en `docker/login-action` contra `ghcr.io`.

---

## Bonus — Reverse proxy con Nginx

En producción solo Nginx publica puertos (`80` y `443`); la API y MongoDB se
quedan accesibles únicamente dentro de la red de Docker.

Para probarlo en local sin desplegar nada:

```bash
docker build --target runner -t todos-api:local ./api
cp .env.production.example .env.production
# edita API_IMAGE=todos-api:local y pon las credenciales de MongoDB
./scripts/blue-green.sh deploy todos-api:local

curl http://localhost/todos          # a traves del proxy
```

Un detalle que suele fallar: **la IP del contenedor `api-blue` / `api-green`
cambia cada vez que se recrea**. Si nginx usa un bloque `upstream` con IPs
fijas, se queda apuntando a una IP muerta después de un
`docker compose restart api-green`. Por eso la configuración resuelve el nombre
en cada petición:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;
set $api_upstream http://api-blue:3000;
proxy_pass $api_upstream;
```

`127.0.0.11` es el DNS interno de Docker y solo funciona dentro de su red, por
lo que esta configuración **no sirve** fuera de un contenedor.

Qué color cuelga de `$api_upstream` es justamente lo que decide la sesión
[Blue-Green](#sesión--blue-green-deployment): un `include` del fichero de estado
`nginx/upstream/active.conf`.

### Con dominio propio

```hcl
# terraform/terraform.tfvars
domain_name        = "midominio.com"
domain_record_name = "@"
```

Terraform crea el registro A apuntando al Droplet. Para HTTPS, sigue los pasos
comentados al final de `nginx/conf.d/default.conf` (certbot + montaje de
`nginx/certs` + descomentar el bloque `listen 443 ssl`).

---

## Sesión — Blue-Green Deployment

La práctica: tomar la aplicación ya contenedorizada y desplegarla con la
estrategia **blue-green**: la versión nueva se levanta en un contenedor aparte
y el tráfico solo cambia cuando la nueva versión está comprobada y sana. Cero
downtime, cero pérdida de datos y rollback en un comando.

### Cómo funciona

- **Dos slots idénticos**, `api-blue` y `api-green`, declarados con la misma
  ancla YAML (`x-api-slot`) en `docker-compose.prod.yml`: misma imagen, mismas
  variables, mismo healthcheck. Al estar definidos con un ancla, no pueden
  divergir.
- **Solo uno recibe tráfico.** El color activo vive en un fichero de estado,
  `nginx/upstream/active.conf`, que nginx incluye en su `server`:

  ```nginx
  set $api_upstream http://api-blue:3000;   # valor por defecto
  include /etc/nginx/upstream/*.conf;       # lo que decide blue-green.sh
  ```

- **Conmutar es escribir ese fichero y recargar**, nunca reiniciar:

  ```bash
  docker compose exec nginx nginx -t        # valida ANTES de tocar nada
  docker compose exec nginx nginx -s reload # recarga en caliente
  ```

  `nginx -s reload` deja terminar las conexiones en vuelo con la configuración
  vieja y las peticiones nuevas ya van al color nuevo: no se corta ni una.

- **MongoDB es único y compartido** por los dos colores, con el mismo volumen
  `todos-mongo-data`. Las dos versiones leen y escriben en la misma base, así
  que la conmutación no implica migración ni pérdida de datos.
- **El color que no sirve se queda en pie** después del despliegue, listo para
  ser el blanco de un rollback inmediato. `blue-green.sh retire` lo para cuando
  ya no lo quieras como respaldo.

### Los comandos

Todo pasa por `scripts/blue-green.sh`. En el servidor está copiado como
`/opt/todos/blue-green.sh`, así que los ejemplos de abajo sirven en ambos casos.

| Comando                  | Qué hace                                                        |
|--------------------------|-----------------------------------------------------------------|
| `deploy <imagen>`        | Despliega en el color inactivo, espera al healthcheck y conmuta. |
| `status`                 | Color activo, salud e imagen de cada slot y respuesta pública.   |
| `switch <blue\|green>`   | Conmuta a un color ya desplegado y `healthy` (cambio manual).     |
| `rollback`               | Devuelve el tráfico al color anterior (el que quedó en pie).     |
| `retire [color]`         | Para el color que no sirve tráfico.                              |
| `verify [--crud]`        | `/health` y CRUD completo contra el puerto público.              |
| `validate`               | Solo valida compose + variables (lo usa Ansible).                |
| `init`                   | Crea `nginx/upstream/active.conf` si falta.                      |

Variables útiles: `WAIT_TIMEOUT` (segundos de espera del healthcheck, 180 por
defecto) y `VERIFY_RETRIES` (intentos de verificación posterior, 10).

### Desplegar una nueva versión

```bash
# en el servidor, dentro de /opt/todos
./blue-green.sh deploy MY_USER/todos-api:sha-9ef012
```

Salida real de una pasada completa (probada en local antes de documentarla):

```text
==> color activo: blue | nuevo color: green | imagen: todos-api:v2
==> asegurando el reverse proxy en marcha...
==> descargando la imagen y levantando api-green SIN tocar el trafico...
 OK api-green healthy y alcanzable desde nginx
 OK trafico conmutado a green (nginx recargado en caliente)
 OK GET http://127.0.0.1:8081/health -> 200
 OK CRUD completo verificado en http://127.0.0.1:8081
==> api-blue queda en pie como blanco de rollback inmediato
```

Pasos que ejecuta, en orden:

1. Lee el color activo en `active.conf` y calcula el inactivo.
2. Escribe la imagen nueva **solo** en `API_IMAGE_<COLOR_INACTIVO>` del
   `.env.production`. El color activo no se toca: conserva la imagen que está
   sirviendo, aunque el fichero se regenere desde Ansible o desde el CI.
3. `docker compose up -d --wait api-<inactivo>`: arranca la versión nueva sin
   que nadie le envíe tráfico todavía.
4. Comprueba su salud dos veces: el healthcheck del propio contenedor y un
   `GET /health` servido **desde la red de nginx**, es decir por el mismo
   camino que usará el tráfico real.
5. Escribe `active.conf` (con `mv` atómico), valida con `nginx -t` y recarga
   con `nginx -s reload`.
6. Verifica `/health` y el CRUD por el puerto público.
7. Deja el color anterior en pie, o lo para con `--stop-previous`.

### Rollback en un comando

```bash
./blue-green.sh rollback          # vuelve al color anterior, ya desplegado y sano
```

No hay rebuild ni pull: la imagen anterior sigue en el host y su contenedor
está parado pero `healthy`. Ese es precisamente el motivo de dejar el color
viejo en pie. Lo mismo desde GitHub: *Actions → CD → Run workflow* con la
casilla **rollback** marcada.

### Probar blue-green en local

```bash
# 1. dos etiquetas de la misma API, para simular dos versiones
docker build --target runner -t todos-api:v1 ./api
docker build --target runner -t todos-api:v2 ./api

# 2. entorno de produccion apuntando a puertos libres
cp .env.production.example .env.production
# edita: API_IMAGE=todos-api:v1, MONGO_ROOT_PASSWORD=<una larga>,
#        HTTP_PORT=8081, HTTPS_PORT=8443

# 3. primer despliegue (arranca en el color inactivo y conmuta)
./scripts/blue-green.sh deploy todos-api:v1

# 4. segunda version: conmuta al otro color y deja v1 de rollback
./scripts/blue-green.sh deploy todos-api:v2
./scripts/blue-green.sh status

# 5. volver a v1 sin rebuild
./scripts/blue-green.sh rollback

# 6. limpiar
docker compose -f docker-compose.prod.yml --env-file .env.production down -v
```

### Qué pasa si algo falla

La regla es: **el tráfico no se mueve hasta que todo está comprobado.**

| Fallo                                            | Consecuencia                                                    |
|--------------------------------------------------|-----------------------------------------------------------------|
| La imagen no se puede descargar del registro      | `AVISO` y se usa la imagen local que ya había en el host.        |
| El color nuevo no llega a `healthy`               | Se para y el despliegue falla: sigue sirviendo el color viejo.   |
| `/health` falla desde la red de nginx             | Igual: aborta **antes** de conmutar.                             |
| `nginx -t` rechaza la configuración               | Se restaura el `active.conf` anterior: el tráfico no se mueve.   |
| El CRUD posterior a la conmutación falla          | **Rollback automático**: se reescribe `active.conf` con el color viejo y se recarga nginx. |

El comando se sale con código distinto de cero en cualquiera de esos casos, así
que el pipeline CD falla y no sigue al smoke test.

Decisiones de diseño:

- **Nginx sin `depends_on` de la API.** En blue-green hay siempre un color
  parado; un `condition: service_healthy` compartido bloquearía el arranque del
  proxy.
- **`include` con glob y valor por defecto.** Si el fichero de estado no
  existe, nginx arranca con blue en vez de romperse.
- **`nginx/upstream/active.conf` no se sincroniza** por rsync ni por Ansible: es
  estado del servidor. Subirlo desde el repo pondría el tráfico en un color que
  puede no estar desplegado.
- **Verificación doble antes de conmutar.** El healthcheck del contenedor no
  basta: también se comprueba que el slot responde desde la red del proxy, que
  es por donde circulará el tráfico de verdad.

---

## Bonus — Monitoreo del despliegue

Dos niveles: un stack de Prometheus para histórico y alertas, y un watchdog
liviano que no instala nada.

### Prometheus + blackbox + cadvisor

```bash
docker compose -f docker-compose.monitoring.yml up -d --wait
# interfaz: http://<servidor>:9090     (/alerts muestra las alertas disparadas)
```

| Servicio             | Para qué                                                        |
|----------------------|-----------------------------------------------------------------|
| `prometheus`         | Guarda métricas y evalúa las alertas de `monitoring/alerts.yml`. |
| `blackbox-exporter`  | Sondas HTTP programadas por Prometheus contra el despliegue.     |
| `cadvisor`           | Métricas de contenedores: CPU, memoria y reinicios de cada slot. |

Las sondas cubren los cuatro caminos que importan:

```text
http://nginx/nginx-health      el proxy: si falla, no entra trafico
http://nginx/health            el color ACTIVO, visto desde el cliente
http://api-blue:3000/health    el slot azul directo
http://api-green:3000/health   el slot verde directo
```

El stack se conecta a la red externa `todos-prod_frontend` (la que crea el
compose de producción), así que no duplica contenedores ni compite por puertos.
La configuración está validada con `promtool check config`.

### Alertas

`monitoring/alerts.yml`:

| Alerta            | Severidad | Significado                                                                        |
|-------------------|-----------|------------------------------------------------------------------------------------|
| `ProxyDown`       | critical  | Nginx no responde: no entra tráfico en absoluto.                                    |
| `ActiveColorDown` | critical  | El color que recibe tráfico no responde a través del proxy. **La que de verdad importa.** |
| `SlotDown`        | warning   | Un slot lleva 10 min caído (puede ser el retirado a propósito tras un despliegue). |
| `SlotRestarted`   | info      | Un slot se ha reiniciado: normal en un despliegue, sospechoso si no lo hubo.        |
| `MonitoringDown`  | warning   | Prometheus no scrapea algo: no confíes en la ausencia de alertas.                   |

No hay Alertmanager configurado: las alertas se ven en `/alerts` y ahí se puede
añadir un destino (correo, Slack, webhook) con el módulo `alerting`.

### Watchdog liviano

Si no quieres Prometheus en el servidor, `scripts/monitor.sh` solo necesita
Docker y curl:

```bash
./scripts/monitor.sh                # tabla de estado actual
./scripts/monitor.sh --watch 5      # refresca cada 5 s
./scripts/monitor.sh --watch 5 --auto-rollback
```

Con `--auto-rollback`, si el color activo o el endpoint público fallan
`FALLAS_MAX` veces seguidas (3 por defecto) ejecuta `blue-green.sh rollback`
sin intervención humana. Desactivado por defecto: activarlo es una decisión
operativa.

---

## Seguridad

Decisiones aplicadas en todo el proyecto:

- **MongoDB nunca se publica.** Vive en una red `internal: true` sin puertos.
- **La API corre como el usuario `node`**, no como root.
- **Imagen mínima:** multi-stage build; la imagen final solo lleva `node_modules`
  de producción y el código, sin devDependencies ni herramientas de build.
- **Sin secretos en el repositorio.** `.env`, `.env.production` y `nginx/certs/`
  están en `.gitignore`; el `.env.production` del servidor va en `0600`.
- **Credenciales efímeras.** El `config.json` de Docker Hub se borra del servidor
  al terminar cada despliegue.
- **Estado del despliegue sólo en el servidor.** `nginx/upstream/active.conf` y
  `.blue-green-state` están en `.gitignore` y no se sincronizan ni por rsync ni
  por Ansible: si viajaran con el código, un push pondría el tráfico en un color
  que puede no estar desplegado.
- **Cloud Firewall + ufw:** dos capas. El tráfico solo entra por 22, 80 y 443.
- **`X-Powered-By` desactivado** y `trust proxy` apagado por defecto: solo se
  activa con `TRUST_PROXY=true` en producción, que es cuando hay un nginx delante.
- **Errores sin filtrar detalles:** el middleware de errores responde siempre un
  `500` genérico y el log con la traza completa solo se escribe si
  `NODE_ENV != production`.
- **Apagado ordenado:** `SIGTERM` deja de aceptar conexiones, cierra la conexión
  de MongoDB y tiene un tiempo máximo (`SHUTDOWN_TIMEOUT_MS`) antes de forzar la
  salida, para que `docker compose stop` no corte peticiones a medias.

Pendientes si esto fuera a producción de verdad:

- La contraseña de MongoDB viaja en una variable de entorno, visible en
  `docker inspect`. Usa Docker secrets (`_FILE`) o un gestor de secretos externo.
- El usuario del grupo `docker` tiene privilegios equivalentes a root. Para
  producción, un socket de Docker autorizado por rootless o un proxy.
- Añade autenticación a la API: ahora cualquiera puede leer y borrar tareas.
- TLS ya está preparado en el nginx, pero hay que emitir el certificado.

---

## Limpieza

```bash
# Parar el stack local (conserva los datos)
docker compose down

# Parar tambien el stack de monitoreo y borrar su serie temporal
docker compose -f docker-compose.monitoring.yml down -v

# En produccion: parar los dos colores, nginx y mongo (conserva el volumen)
docker compose -f docker-compose.prod.yml --env-file .env.production down

# Liberar el servidor y dejar de pagar
terraform -chdir=terraform destroy

# Borrar también las imágenes construidas en local
docker image prune -a
```