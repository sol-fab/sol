FROM node:22-alpine AS build
WORKDIR /src
COPY serverless/task_consumer_ts/package.json serverless/task_consumer_ts/tsconfig.json ./
RUN npm install
COPY serverless/task_consumer_ts/src ./src
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY --from=build /src/dist ./dist
COPY --from=build /src/package.json ./package.json
USER 65534
ENV PORT=8080
CMD ["node", "dist/pubsub.js"]
