FROM node:22-alpine AS build
WORKDIR /src
COPY serverless/task_consumer_ts/package.json serverless/task_consumer_ts/tsconfig.json ./
RUN npm install
COPY serverless/task_consumer_ts/src ./src
RUN npm run build

FROM public.ecr.aws/lambda/nodejs:22
WORKDIR ${LAMBDA_TASK_ROOT}
COPY --from=build /src/dist/index.js ./index.js
CMD ["index.handler"]
