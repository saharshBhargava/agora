# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS build
RUN npm install -g pnpm@12.14.0
WORKDIR /app
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY server/package.json server/
COPY web/package.json web/
RUN pnpm install --frozen-lockfile
COPY server server
COPY web web
RUN pnpm -C web build && pnpm -C server build

FROM node:22-bookworm-slim
RUN npm install -g pnpm@12.14.0
WORKDIR /app
ENV NODE_ENV=production
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
COPY server/package.json server/
COPY web/package.json web/
# Server runtime deps only (sharp builds/downloads its binary here); web is a static export.
RUN pnpm install --frozen-lockfile --prod --filter dibs-server
COPY --from=build /app/server/dist server/dist
COPY server/assets server/assets
COPY --from=build /app/web/out web/out
ENV PORT=3000 DETECTOR=diff VISION=stub PRICE=stub PAYMENTS=sim LAST_CALL_MS=5000
EXPOSE 3000
CMD ["node", "server/dist/index.js"]
