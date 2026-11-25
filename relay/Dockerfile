FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json tsconfig.json ./
RUN npm ci
COPY src ./src
RUN npm run build

FROM node:22-alpine
ENV NODE_ENV=production
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist
# The census file's folder (CENSUS_FILE, deploy/relay/compose.yaml mounts a volume here). Docker fills a new named
# volume from the image's folder, ownership included, so a fresh volume is writable by `node`.
RUN mkdir /data && chown node:node /data
USER node
EXPOSE 8080
CMD ["node", "dist/index.js"]
