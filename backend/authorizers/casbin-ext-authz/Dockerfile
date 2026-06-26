# Stage 1: Build the Go binary
FROM golang:1.23-alpine AS builder

RUN apk add --no-cache ca-certificates

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /casbin-ext-authz .

# Stage 2: Minimal runtime image
FROM scratch

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /casbin-ext-authz /casbin-ext-authz
COPY casbin_model.conf /casbin_model.conf
COPY casbin_policy.csv /casbin_policy.csv

EXPOSE 9001

ENTRYPOINT ["/casbin-ext-authz", "-model", "/casbin_model.conf", "-policy", "/casbin_policy.csv"]
