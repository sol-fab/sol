FROM node:22-alpine AS build
WORKDIR /src
COPY {{dir}}/package.json ./
RUN npm install
COPY {{dir}} ./
RUN npm run build

FROM node:22-alpine
WORKDIR /app
COPY --from=build /src/node_modules ./node_modules
COPY --from=build /src/dist ./dist
COPY --from=build /src/package.json ./package.json
USER 65534
CMD ["node", "dist/index.js"]
