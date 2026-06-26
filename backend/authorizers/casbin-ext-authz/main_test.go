package main

import (
	"context"
	"testing"

	"github.com/casbin/casbin/v2"

	authv3 "github.com/envoyproxy/go-control-plane/envoy/service/auth/v3"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// newTestEnforcer creates a Casbin SyncedEnforcer from the local model and policy files.
func newTestEnforcer(t *testing.T) *casbin.SyncedEnforcer {
	t.Helper()
	e, err := casbin.NewSyncedEnforcer("casbin_model.conf", "casbin_policy.csv")
	require.NoError(t, err)
	require.NotNil(t, e)
	return e
}

// newTestServer creates an authorizationServer with an enforcer loaded from local files.
func newTestServer(t *testing.T) *authorizationServer {
	t.Helper()
	return &authorizationServer{enforcer: newTestEnforcer(t)}
}

// makeCheckRequest builds a CheckRequest with the given HTTP attributes.
func makeCheckRequest(ctx context.Context, t *testing.T, userToken, path, method string) *authv3.CheckRequest {
	t.Helper()
	headers := map[string]string{}
	if userToken != "" {
		headers["authorization"] = "Bearer " + userToken
	}
	return &authv3.CheckRequest{
		Attributes: &authv3.AttributeContext{
			Request: &authv3.AttributeContext_Request{
				Http: &authv3.AttributeContext_HttpRequest{
					Path:    path,
					Method:  method,
					Headers: headers,
				},
			},
		},
	}
}

func TestCheck_AdminUserAllowsAdminEndpoint(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), makeCheckRequest(context.Background(), t, "alice", "/api/admin/users", "GET"))
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.OK, st.Code(), "admin should be allowed to access /api/admin/*")
}

func TestCheck_AdminUserAllowsApiEndpoint(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), makeCheckRequest(context.Background(), t, "alice", "/api/data", "GET"))
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.OK, st.Code(), "admin should be allowed to access /api/*")
}

func TestCheck_UserAllowsPublicEndpoint(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), makeCheckRequest(context.Background(), t, "bob", "/api/public/info", "GET"))
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.OK, st.Code(), "user should be allowed to access /api/public/*")
}

func TestCheck_UserDeniedAdminEndpoint(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), makeCheckRequest(context.Background(), t, "bob", "/api/admin/users", "GET"))
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.PermissionDenied, st.Code(), "user should be denied access to /api/admin/*")
	assert.Equal(t, "forbidden", st.Message())
}

func TestCheck_ViewerDeniedUserEndpoint(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), makeCheckRequest(context.Background(), t, "charlie", "/api/user/profile", "GET"))
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.PermissionDenied, st.Code(), "viewer should be denied access to /api/user/*")
}

func TestCheck_NoAuthHeaderReturnsUnauthenticated(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), makeCheckRequest(context.Background(), t, "", "/api/public/info", "GET"))
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.Unauthenticated, st.Code(), "missing auth should return Unauthenticated")
}

func TestCheck_UnknownUserDenied(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), makeCheckRequest(context.Background(), t, "mallory", "/api/public/info", "GET"))
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.PermissionDenied, st.Code(), "unknown user should be denied")
}

func TestCheck_MissingAttributes(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), &authv3.CheckRequest{})
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.InvalidArgument, st.Code(), "missing attributes should return InvalidArgument")
}

func TestCheck_MissingHttpRequest(t *testing.T) {
	srv := newTestServer(t)
	resp, err := srv.Check(context.Background(), &authv3.CheckRequest{
		Attributes: &authv3.AttributeContext{},
	})
	require.NoError(t, err)
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.InvalidArgument, st.Code(), "missing HTTP request should return InvalidArgument")
}

func TestCasbinModelAndPolicyLoad(t *testing.T) {
	e, err := casbin.NewSyncedEnforcer("casbin_model.conf", "casbin_policy.csv")
	require.NoError(t, err, "Casbin enforcer should load without error")

	// Verify admin role has admin access.
	allowed, err := e.Enforce("alice", "/api/admin/users", "GET")
	require.NoError(t, err)
	assert.True(t, allowed, "alice (admin) should be allowed /api/admin/users GET")

	// Verify viewer does NOT have admin access.
	denied, err := e.Enforce("charlie", "/api/admin/users", "GET")
	require.NoError(t, err)
	assert.False(t, denied, "charlie (viewer) should NOT be allowed /api/admin/users GET")

	// Verify user has public access.
	allowed, err = e.Enforce("bob", "/api/public/data", "GET")
	require.NoError(t, err)
	assert.True(t, allowed, "bob (user) should be allowed /api/public/data GET")
}

func TestExtractUser_FromAuthHeader(t *testing.T) {
	headers := map[string]string{
		"authorization": "Bearer alice-jwt-token",
	}
	user := extractUser(headers)
	assert.Equal(t, "alice-jwt-token", user)
}

func TestExtractUser_EmptyHeaders(t *testing.T) {
	headers := map[string]string{}
	user := extractUser(headers)
	assert.Equal(t, "", user)
}

func TestExtractUser_FromEnvoyDownstreamURL(t *testing.T) {
	headers := map[string]string{
		"x-envoy-downstream-url": "spiffe://cluster.local/ns/hpa/sa/envoy",
	}
	user := extractUser(headers)
	assert.Equal(t, "spiffe://cluster.local/ns/hpa/sa/envoy", user)
}

func TestCheckResponse_OkResponseFormat(t *testing.T) {
	resp := okResponse()
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.OK, st.Code())
	_, ok := resp.HttpResponse.(*authv3.CheckResponse_OkResponse)
	assert.True(t, ok, "okResponse should have OkResponse type")
}

func TestCheckResponse_DeniedResponseFormat(t *testing.T) {
	resp := deniedResponse(codes.PermissionDenied, "forbidden")
	require.NotNil(t, resp)
	st := status.FromProto(resp.GetStatus())
	assert.Equal(t, codes.PermissionDenied, st.Code())
	assert.Equal(t, "forbidden", st.Message())
	dr, ok := resp.HttpResponse.(*authv3.CheckResponse_DeniedResponse)
	assert.True(t, ok, "deniedResponse should have DeniedResponse type")
	assert.Contains(t, dr.DeniedResponse.Body, "forbidden")
}
