package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"os"
	"strings"

	"github.com/casbin/casbin/v2"
	"github.com/casbin/casbin/v2/util"

	corev3 "github.com/envoyproxy/go-control-plane/envoy/config/core/v3"
	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"
	typev3 "github.com/envoyproxy/go-control-plane/envoy/type/v3"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	gogrpcstatus "google.golang.org/grpc/status"
)

const (
	defaultPort = ":9001"
)

// authorizationServer implements envoy.service.auth.v3.Authorization.
type authorizationServer struct {
	authv3.UnimplementedAuthorizationServer
	enforcer *casbin.SyncedEnforcer
}

// Check evaluates an incoming HTTP request against Casbin RBAC rules.
func (s *authorizationServer) Check(ctx context.Context, req *authv3.CheckRequest) (*authv3.CheckResponse, error) {
	attrs := req.GetAttributes()
	if attrs == nil {
		log.Printf("INFO: Check() missing attributes, denying request")
		return deniedResponse(codes.InvalidArgument, "missing attributes"), nil
	}

	httpReq := attrs.GetRequest().GetHttp()
	if httpReq == nil {
		log.Printf("INFO: Check() missing HTTP request attributes, denying request")
		return deniedResponse(codes.InvalidArgument, "missing HTTP request"), nil
	}

	path := httpReq.GetPath()
	method := httpReq.GetMethod()
	host := httpReq.GetHost()
	headers := httpReq.GetHeaders()

	// Extract user identity from the Authorization header.
	// Format: "Bearer <token>". The user is extracted from the token subject.
	// For Casbin RBAC, we use the raw token prefix as the subject placeholder
	// since actual JWT validation happens upstream (Casdoor).
	// In production, Envoy's JWT filter extracts the user into a header.
	user := extractUser(headers)

	log.Printf("INFO: Check() user=%q path=%q method=%q host=%q", user, path, method, host)

	if user == "" {
		log.Printf("INFO: Check() no authenticated user, denying request to %s %s", method, path)
		return deniedResponse(codes.Unauthenticated, "missing authentication"), nil
	}

	// Evaluate Casbin policy: sub (user) vs obj (path) vs act (method).
	allowed, err := s.enforcer.Enforce(user, path, method)
	if err != nil {
		log.Printf("ERROR: Check() Casbin enforcer error: %v", err)
		return deniedResponse(codes.Internal, "authorization error"), nil
	}

	if allowed {
		log.Printf("INFO: Check() user=%q ALLOW %s %s", user, method, path)
		return okResponse(), nil
	}

	log.Printf("INFO: Check() user=%q DENY %s %s", user, method, path)
	return deniedResponse(codes.PermissionDenied, "forbidden"), nil
}

func main() {
	port := os.Getenv("CASBIN_GRPC_PORT")
	if port == "" {
		port = defaultPort
	}
	modelPath := flag.String("model", "casbin_model.conf", "path to Casbin model file")
	policyPath := flag.String("policy", "casbin_policy.csv", "path to Casbin policy file")
	flag.Parse()

	enforcer, err := casbin.NewSyncedEnforcer(*modelPath, *policyPath)
	if err != nil {
		log.Fatalf("FATAL: failed to create Casbin enforcer: %v", err)
	}
	// Enable role matching using keymatch for path patterns.
	enforcer.AddFunction("keyMatch", util.KeyMatchFunc)
	enforcer.AddFunction("keyMatch3", util.KeyMatch3Func)

	lis, err := net.Listen("tcp", port)
	if err != nil {
		log.Fatalf("FATAL: failed to listen on %s: %v", port, err)
	}

	srv := grpc.NewServer()
	authv3.RegisterAuthorizationServer(srv, &authorizationServer{enforcer: enforcer})

	log.Printf("INFO: Casbin ext_authz gRPC server starting on %s (model=%s, policy=%s)", port, *modelPath, *policyPath)
	if err := srv.Serve(lis); err != nil {
		log.Fatalf("FATAL: gRPC server failed: %v", err)
	}
}

// extractUser extracts the user identity from request headers.
// It checks Authorization header for Bearer token, then falls back to
// x-envoy-downstream-url header.
func extractUser(headers map[string]string) string {
	// Check standard Authorization header.
	if auth, ok := headers["authorization"]; ok {
		// Strip "Bearer " prefix to get the token.
		if trimmed, found := strings.CutPrefix(auth, "Bearer "); found {
			return trimmed
		}
		// Also check lowercase variants.
		for _, prefix := range []string{"bearer ", "BEARER "} {
			if trimmed, found := strings.CutPrefix(auth, prefix); found {
				return trimmed
			}
		}
	}

	// Fallback to x-envoy-downstream-url if present (set by Envoy).
	if downstreamURL, ok := headers["x-envoy-downstream-url"]; ok {
		return downstreamURL
	}

	return ""
}

// okResponse builds a CheckResponse that allows the request.
func okResponse() *authv3.CheckResponse {
	return &authv3.CheckResponse{
		Status: gogrpcstatus.New(codes.OK, "").Proto(),
		HttpResponse: &authv3.CheckResponse_OkResponse{
			OkResponse: &authv3.OkHttpResponse{
				ResponseHeadersToAdd: []*corev3.HeaderValueOption(nil),
			},
		},
	}
}

// deniedResponse builds a CheckResponse that denies the request with the given gRPC code.
func deniedResponse(code codes.Code, reason string) *authv3.CheckResponse {
	httpStatus := typev3.StatusCode_Forbidden
	if code == codes.Unauthenticated {
		httpStatus = typev3.StatusCode_Unauthorized
	}

	return &authv3.CheckResponse{
		Status: gogrpcstatus.New(code, reason).Proto(),
		HttpResponse: &authv3.CheckResponse_DeniedResponse{
			DeniedResponse: &authv3.DeniedHttpResponse{
				Status: &typev3.HttpStatus{
					Code: httpStatus,
				},
				Body: fmt.Sprintf("access denied: %s", reason),
			},
		},
	}
}

// Ensure authorizationServer implements the AuthorizationServer interface.
var _ authv3.AuthorizationServer = (*authorizationServer)(nil)
