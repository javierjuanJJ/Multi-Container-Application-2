# syntax=docker/dockerfile:1

# Imagen base. Sobrescribir con --build-arg NODE_VERSION=24-alpine si hace falta.
ARG NODE_VERSION=22-alpine


# ---------------------------------------------------------------------------
# deps: dependencias de produccion, instaladas en una capa cacheable.
# Se separan del runner para que `npm ci` no se re-ejecute en cada cambio de codigo.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION} AS deps
WORKDIR /usr/src/app

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev --no-audit --no-fund


# ---------------------------------------------------------------------------
# dev: dependencias completas + nodemon, con el codigo montado por compose.
# Uso:  docker compose --profile dev up api   (o compose.yaml con target: dev)
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION} AS dev
ENV NODE_ENV=development
WORKDIR /usr/src/app

COPY package.json package-lock.json ./

RUN --mount=type=cache,target=/root/.npm \
    npm ci --no-audit --no-fund

COPY . .

EXPOSE 3000

CMD ["npm", "run", "dev"]


# ---------------------------------------------------------------------------
# runner: imagen final de produccion. Sin build tools, sin devDependencies y
# ejecutando como el usuario `node` (uid 1000) que ya existe en la imagen oficial.
# ---------------------------------------------------------------------------
FROM node:${NODE_VERSION} AS runner

ENV NODE_ENV=production \
    PORT=3000

WORKDIR /usr/src/app

COPY --from=deps --chown=node:node /usr/src/app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

USER node

EXPOSE 3000

# El healthcheck usa fetch de Node para no depender de curl/wget en la imagen.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD node -e "fetch('http://127.0.0.1:' + (process.env.PORT || 3000) + '/health').then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))"

CMD ["node", "src/index.js"]