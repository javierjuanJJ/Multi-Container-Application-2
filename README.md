# Multi-Container Application

Aplicación de lista de tareas desplegada con **Docker Compose**, provisionada con
**Terraform + Ansible** y publicada con un pipeline de **GitHub Actions**.

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
- [Backups automáticos de la base de datos](#backups-automáticos-de-la-base-de-datos)
- [Bonus — Reverse proxy con Nginx](#bonus--reverse-proxy-con-nginx)
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
├── docker-compose.prod.yml       # REQ 2/3 + bonus: MongoDB + API + Nginx en :80/:443
├── nginx/conf.d/default.conf     # bonus: configuración del reverse proxy
├── terraform/                    # REQ 2: Droplet + Cloud Firewall + DNS
├── ansible/                      # REQ 2: rol docker + rol app (despliegue con compose)
│   ├── site.yml                  # endurecimiento base del Droplet
│   ├── todos.yml                 # instala Docker y despliega el stack
│   └── roles/{docker,app}/
├── .github/workflows/
│   ├── ci.yml                    # REQ 3: smoke test del CRUD en cada push
│   ├── cd.yml                    # REQ 3: publica la imagen y despliega
│   └── backup.yml                # copia de MongoDB a R2 cada 12 horas
├── scripts/
│   ├── mongo-backup.sh           # mongodump -> tarball (corre en el servidor)
│   └── mongo-restore.sh          # descarga de R2 y restaura
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
- **`app`** — copia al servidor `docker-compose.prod.yml` y la configuración de
  nginx, genera el `.env.production` en modo `0600`, valida el resultado con
  `docker compose config` y lanza `docker compose pull` + `up -d --wait`.

```bash
# 1) Endurecer el Droplet (usuario admin, SSH sin contraseña, ufw)
ansible-playbook site.yml

# 2) Instalar Docker y desplegar el stack
ansible-vault encrypt_string 'una-contrasena-larga-y-aleatoria' --name 'app_mongo_password'
ansible-playbook todos.yml --ask-vault-pass -e app_image=MI_USUARIO_DOCKERHUB/todos-api:latest
```

`todos.yml` valida el compose antes de tocar nada y espera a que todos los
servicios estén `healthy`. MongoDB no se recrea en cada despliegue, así que el
volumen sobrevive intacto.

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
   ficheros de compose, nginx y el `.env.production`; genera las credenciales de
   Docker Hub en el runner y las copia al servidor; y ejecuta
   `docker compose pull` + `up -d --remove-orphans --wait`.
3. **smoke-test** — comprueba `/health` y el CRUD completo contra el servidor ya
   desplegado, entrando por el reverse proxy.

Detalle importante: `ssh host bash -s` **no reenvía el entorno local**, así que el
token de Docker Hub viaja dentro de un `config.json` generado con `docker login`
en el runner y copiado por `rsync`, nunca en la línea de comandos. El servidor lo
borra al terminar el despliegue.

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

## Backups automáticos de la base de datos

Copia de MongoDB cada 12 horas en un tarball, subida a **Cloudflare R2** (tiene
tier gratuito de almacenamiento), más el script para restaurarla.

### `backup.yml` — copia programada

Cron `0 */12 * * *` (00:00 y 12:00 UTC) y a mano desde *Actions → DB Backup →
Run workflow*:

1. **config** — comprueba los secrets al principio y falla con un mensaje
   claro, no a mitad de la copia.
2. **volcado** — por SSH ejecuta `scripts/mongo-backup.sh` en el servidor. El
   script localiza el contenedor de MongoDB, hace `mongodump` dentro de él,
   empaqueta el resultado en un `.tar.gz` con un `manifest.txt` y devuelve **una
   única línea** por stdout: la ruta del tarball. Todo lo demás va a stderr, que
   es lo que se ve en los logs.
3. **subida** — copia el tarball al runner, verifica el `tar`, lo sube a R2 con
   la CLI de AWS y confirma con `head-object` que el tamaño remoto es igual al
   local: si no lo es, la copia está incompleta aunque `aws s3 cp` haya
   devuelto 0.
4. **retención** — borra las copias de más de `BACKUP_RETENTION_DAYS` días
   (30 por defecto; `0` la desactiva).
5. **limpieza** — borra el temporal del servidor y el `~/.aws` del runner,
   pase lo que pase (`if: always()`).

Ni la API ni MongoDB abren puertos: el workflow entra al servidor por SSH con
las mismas credenciales que `cd.yml` y habla con el contenedor por el socket de
Docker. La base sigue sin publicarse.

#### Secrets y variables

*Settings → Secrets and variables → Actions.*

| Secret                | Obligatorio | Descripción                                          |
|-----------------------|-------------|------------------------------------------------------|
| `R2_ACCOUNT_ID`       | sí          | Account ID de Cloudflare (R2 → Details)              |
| `R2_ACCESS_KEY_ID`    | sí          | ID de una API token de R2 con *Object Read & Write*  |
| `R2_SECRET_ACCESS_KEY`| sí          | Secreto de esa API token                             |
| `SERVER_HOST`         | sí          | IP del Droplet (el mismo que usa `cd.yml`)           |
| `SERVER_SSH_KEY`      | sí          | Clave privada SSH (la misma que usa `cd.yml`)        |
| `SERVER_HOST_KEY`     | no          | Host key del Droplet (si no, se usa `ssh-keyscan`)   |

| Variable               | Por defecto  | Descripción                              |
|------------------------|--------------|------------------------------------------|
| `R2_BUCKET_NAME`       | `todos-backups` | Bucket de R2                           |
| `R2_PREFIX`            | `backups/mongo` | Prefijo dentro del bucket              |
| `BACKUP_RETENTION_DAYS`| `30`         | Días conservados (`0` = no prunar)        |
| `MONGO_DATABASE`       | `todos`      | Base de datos copiada                     |
| `SERVER_USER`          | `deploy`     | Usuario SSH en el servidor                |

Para poner R2 en marcha:

1. *R2 → Create bucket* (por ejemplo `todos-backups`), región automática.
2. *My Profile → API Tokens → Create Token*, plantilla **Object Read & Write**
   limitada al bucket. El `Account ID` está en *R2 → Details*.
3. Copia el ID y el secreto de la token a los tres secrets de arriba.

Cada copia acaba en
`s3://todos-backups/backups/mongo/<base>-<timestamp>.tar.gz`, por ejemplo
`backups/mongo/todos-20261006T000000Z.tar.gz`.

### Restaurar (objetivo extendido)

`scripts/mongo-restore.sh` descarga la copia más reciente de R2 (o la que le
indiques) y la restaura en el contenedor:

```bash
# el script corre en el host donde esta el contenedor de MongoDB:
#   scp scripts/mongo-restore.sh <servidor>:/tmp/
export R2_ACCOUNT_ID=... R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=...

./scripts/mongo-restore.sh --list        # que hay en R2
./scripts/mongo-restore.sh --dry-run     # descarga y verifica, sin tocar datos
./scripts/mongo-restore.sh               # restaura la mas reciente (pide confirmacion)
./scripts/mongo-restore.sh <clave>       # una copia concreta

# sin terminal interactiva hay que confirmar a mano:
ssh <servidor> 'bash -s -- --yes' < scripts/mongo-restore.sh
```

La restauración usa `mongorestore --drop`: **sustituye** las colecciones
existentes por las del backup. Por eso exige confirmación (`--yes` si no hay
terminal) y por eso `--dry-run` —que solo descarga, comprueba el tar y enseña el
`manifest.txt`— debería ser el primer paso siempre.

Si no está instalada la CLI de AWS, el script usa la imagen `amazon/aws-cli` por
Docker: en el servidor no hay que instalar nada.

### Alternativa: cron en el servidor

El mismo script sirve si prefieres no depender de GitHub. Un wrapper que vuelca
y sube, y su línea de cron:

```bash
#!/usr/bin/env bash
# /opt/scripts/backup.sh
set -euo pipefail
path="$(MONGO_DATABASE=todos /opt/scripts/mongo-backup.sh)"   # -> $HOME/backups
aws s3 cp "$path" "s3://todos-backups/backups/mongo/$(basename "$path")" \
  --endpoint-url "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
```

```cron
# /etc/cron.d/mongo-backup (o el crontab del usuario): las variables van en
# lineas propias, no como prefijo del comando
R2_ACCOUNT_ID=...
R2_ACCESS_KEY_ID=...
R2_SECRET_ACCESS_KEY=...
0 */12 * * * deploy /opt/scripts/backup.sh >> /var/log/mongo-backup.log 2>&1
```

### Decisiones de diseño

- **El volcado ocurre en el servidor y la subida en el runner.** Las
  credenciales de R2 solo existen en los secrets de GitHub: si el Droplet se
  compromete, el atacante no puede borrar ni sobrescribir las copias.
- **La contraseña de MongoDB no aparece en ningún `ps`.** El script viaja por
  stdin a `bash -s` y la contraseña se escribe en el stdin de un `sh` dentro del
  contenedor: solo `mongodump` la ve, y ahí dentro. En el servidor no se
  escribe en ningún fichero.
- **Tarball con manifiesto.** Cada copia lleva `manifest.txt` (fecha, base,
  contenedor y versión de MongoDB), así que se sabe qué hay dentro sin fiarse
  del nombre del fichero.
- **Sin instalar nada.** La imagen oficial de MongoDB ya trae las Database Tools
  (`mongodb-org-tools`, con `mongodump` y `mongorestore`), `mongosh` y `tar`.
- **Verificación en los dos extremos:** `tar -tzf` antes de subir y
  `head-object` después. Un backup que no se puede restaurar no es un backup.

---

## Bonus — Reverse proxy con Nginx

En producción solo Nginx publica puertos (`80` y `443`); la API y MongoDB se
quedan accesibles únicamente dentro de la red de Docker.

Para probarlo en local sin desplegar nada:

```bash
cp .env.production.example .env.production
# edita API_IMAGE para que apunte a una imagen existente y pon las credenciales
docker compose -f docker-compose.prod.yml --env-file .env.production \
  up -d --wait

curl http://localhost/todos          # a traves del proxy
```

Un detalle que suele fallar: **la IP del contenedor `api` cambia cada vez que se
recrea**. Si nginx usa un bloque `upstream`, se queda apuntando a una IP muerta
después de un `docker compose restart api`. Por eso la configuración resuelve el
nombre en cada petición:

```nginx
resolver 127.0.0.11 valid=10s ipv6=off;
set $api_upstream http://api:3000;
proxy_pass $api_upstream;
```

`127.0.0.11` es el DNS interno de Docker y solo funciona dentro de su red, por
lo que esta configuración **no sirve** fuera de un contenedor.

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
- **Copias fuera del servidor.** MongoDB se vuelca a Cloudflare R2 cada 12 horas
  con 30 días de retención. La contraseña de la base no aparece en la línea de
  comandos (viaja por stdin) y las credenciales de R2 solo existen en los
  secrets de GitHub: el servidor no puede alterar las copias.
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

# Liberar el servidor y dejar de pagar
terraform -chdir=terraform destroy

# Borrar también las imágenes construidas en local
docker image prune -a
```