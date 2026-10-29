FROM node:22-alpine AS build
WORKDIR /src
COPY app/demo_ts/probe_ts_fn/package.json app/demo_ts/probe_ts_fn/tsconfig.json ./
RUN npm install
COPY app/demo_ts/probe_ts_fn/src ./src
RUN npm run build

FROM public.ecr.aws/lambda/nodejs:22
WORKDIR ${LAMBDA_TASK_ROOT}
COPY --from=build /src/dist/index.js ./index.js
CMD ["index.handler"]
