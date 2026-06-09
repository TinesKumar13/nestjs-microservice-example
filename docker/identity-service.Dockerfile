FROM node:22-alpine AS base

WORKDIR /usr/src/app

COPY package.json package-lock.json ./
RUN npm ci

COPY . .
RUN npm run build identity-service


FROM node:22-alpine AS production

RUN addgroup -S appgroup && adduser -S appuser -G appgroup

WORKDIR /usr/src/app

COPY --from=base /usr/src/app/package.json ./
COPY --from=base /usr/src/app/package-lock.json ./
COPY --from=base /usr/src/app/dist/apps/identity-service ./dist/apps/identity-service
COPY --from=base /usr/src/app/dist/libs ./dist/libs
COPY --from=base /usr/src/app/libs/shared/src/contracts/grpc/proto ./dist/libs/shared/src/contracts/grpc/proto

RUN npm ci --omit=dev && npm cache clean --force

USER appuser

EXPOSE 50051

CMD ["node", "dist/apps/identity-service/src/main"]

