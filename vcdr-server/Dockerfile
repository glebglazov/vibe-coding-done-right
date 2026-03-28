FROM golang:1.23-alpine AS builder

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY *.go ./

RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o vcdr-server .

FROM alpine:3.20

RUN apk add --no-cache ca-certificates

COPY --from=builder /app/vcdr-server /usr/local/bin/vcdr-server

EXPOSE 8080

ENTRYPOINT ["vcdr-server"]
