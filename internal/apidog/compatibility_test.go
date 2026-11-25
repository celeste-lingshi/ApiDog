package apidog

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestMain(m *testing.M) {
	if len(os.Args) == 2 && os.Args[1] == AuthWorkerArgument {
		RunAuthWorker(os.Stdin, os.Stdout)
		return
	}
	os.Exit(m.Run())
}

func TestRequestFlow(t *testing.T) {
	d := NewDraft()
	d.Method, d.URL = "POST", "{{baseUrl}}/{hostname}/ping?existing=1"
	d.Variables = map[string]string{"baseUrl": "https://example.com", "hostname": "node/a b", "user": "小明"}
	d.Headers = []Field{field("X-Tag", Text("one:two")), field("X-Node", Text("{hostname}"))}
	d.Query = []Field{field("search", Text("a+b /")), field("verbose", nil)}
	d.Body = Text(`{"user":"{{user}}"}`)
	d.Auth = Auth{Mode: "bearer", Secret: Text("abc")}
	if names := d.VariableNames(); !reflect.DeepEqual(names, []string{"baseUrl", "hostname", "user"}) {
		t.Fatal(names)
	}
	p, err := Prepare(t.Context(), d, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if p.url.String() != "https://example.com/node%2Fa%20b/ping?existing=1&search=a%2Bb%20%2F&verbose" ||
		p.headers.Get("X-Node") != "node/a b" || p.headers.Get("Authorization") != "Bearer abc" ||
		p.headers.Get("Content-Type") != "application/json" || value(p.body) != `{"user":"小明"}` {
		t.Fatalf("错误的请求：%v", p)
	}
	d.Headers = append(d.Headers, field("authorization", Text("duplicate")))
	if _, err = Prepare(t.Context(), d, time.Now()); err == nil {
		t.Fatal("接受了重复认证")
	}
	for _, address := range []string{"file:///tmp/example", "https://example.com/{missing}"} {
		d = NewDraft()
		d.URL = address
		if _, err := Prepare(t.Context(), d, time.Now()); err == nil {
			t.Fatal(address)
		}
	}
	d = NewDraft()
	d.URL = "https://example.com"
	d.Body = Text("{{unused}}")
	if p, err := Prepare(t.Context(), d, time.Now()); err != nil || p.body != nil {
		t.Fatal("GET 请求体应忽略", err)
	}
}

func TestCurlImport(t *testing.T) {
	for _, source := range []string{
		`curl --location 'https://example.com/ping?q=one%2Btwo&flag&n=1&n=2' -H 'Content-Type: application/json' -H 'Authorization: Bearer abc' -H 'X-Note: It'\''s there' --data-raw '{"ok":true,"text":"$literal"}'`,
		`curl -G --data-urlencode 'title=a+b /' https://example.com`,
		`curl --data-urlencode 'vip=a+b' https://example.com`,
		`curl -I --user 'demo:' https://example.com`,
		`curl -H 'X-API-Key: token' https://example.com`,
		`curl --data-raw '' https://example.com`,
	} {
		d, err := ImportCurl(source)
		if err != nil {
			t.Fatal(source, err)
		}
		p, err := Prepare(t.Context(), d, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		d2, err := ImportCurl(p.Command())
		if err != nil {
			t.Fatal(err)
		}
		second, err := Prepare(t.Context(), d2, time.Now())
		if err != nil {
			t.Fatal(err)
		}
		if second.url.String() != p.url.String() || second.method != p.method || !reflect.DeepEqual(second.body, p.body) || !reflect.DeepEqual(second.headers, p.headers) {
			t.Fatal("往返 cURL 后请求发生变化", source)
		}
	}
	source := `
api_host=demo.example.test
  api_path=/api/v1/list
  api_ts=$(date +%s)
  api_sign=$(printf '%s' "${LIST_API_KEY}_${LIST_SECRET}_${api_path}_${api_ts}" |
    openssl dgst -sha256 -hmac "$LIST_SECRET" -binary |
    openssl base64 -A | tr '/+' '_-' | tr -d '=')

  curl -fsS --noproxy "$api_host" --resolve "$api_host:8009:127.0.0.1" \
    --get "http://$api_host:8009$api_path" \
    --data-urlencode 'value=a+b' \
    --data-urlencode "key=$LIST_API_KEY" \
    --data-urlencode "timestamp=$api_ts" \
    --data-urlencode "sign=$api_sign" |
    jq -r '.reason[]?.port'`
	d, err := ImportCurl(source)
	if err != nil {
		t.Fatal(err)
	}
	if d.URL != "http://{{api_host}}:8009{{api_path}}" || d.Auth.SigningURI != "{{api_path}}" || len(d.Query) != 1 ||
		d.Auth.SigningKeyField != "key" || d.Auth.Secret != nil || d.Projection != ".reason[]?.port" {
		t.Fatalf("签名命令格式化错误：%+v", d)
	}
	d.Variables["api_host"], d.Variables["api_path"] = "updated.example.test", "/api/v2/list"
	d.Auth.Name, d.Auth.Secret = "demo-key", Text("demo-secret")
	p, err := Prepare(t.Context(), d, time.Unix(1700000000, 0))
	if err != nil {
		t.Fatal(err)
	}
	if p.route.Resolve != "updated.example.test:8009:127.0.0.1" || p.url.Path != "/api/v2/list" ||
		p.url.Query().Get("timestamp") != "1700000000" || len(p.url.Query().Get("sign")) != 43 || !strings.HasSuffix(p.Command(), "jq -r '.reason[]?.port'") {
		t.Fatal(p.Command())
	}
	for _, v := range []string{
		`curl https://example.com | echo test`, `curl "https://example.com/$(hostname)"`,
		`curl --data-binary @example.json https://example.com`, `curl --form 'document=@file.txt' https://example.com`,
		`curl https://example.com https://another.example`,
		strings.ReplaceAll(source, "date +%s", "date +%N"), strings.ReplaceAll(source, "sign=$api_sign", "sign=prefix$api_sign"),
		strings.ReplaceAll(source, "127.0.0.1", "invalid-address"), strings.ReplaceAll(source, ".reason[]?.port", ".reason | length"),
	} {
		if _, err := ImportCurl(v); err == nil {
			t.Fatal("接受了不支持的命令")
		}
	}
}

func TestScriptAuthentication(t *testing.T) {
	d := NewDraft()
	d.URL = "https://example.com/items?existing=1"
	d.Method = "POST"
	d.Body = Text(`{"payload":true}`)
	d.Auth = Auth{Mode: "script", ScriptInputs: []Field{field("secret", Text("abc"))}, Script: Text(`
		const signature = crypto.hmacSHA256Hex(inputs.secret, request.uri + "_" + timestamp);
		return {headers: {"X-Sign": signature}, query: {"stamp":timestamp},
			body: {"content":request.query[0].name, "encoded":crypto.base64(request.method)}};
	`)}
	p, err := Prepare(t.Context(), d, time.Unix(1700000000, 0))
	if err != nil {
		t.Fatal(err)
	}
	if len(p.headers.Get("X-Sign")) != 64 || p.url.Query().Get("stamp") != "1700000000" ||
		value(p.body) != `{"content":"existing","encoded":"UE9TVA==","payload":true}` {
		t.Fatal(p.Command())
	}
	for _, untrusted := range []string{`return {query:{a:2}};`, `return {bad:true};`, `return {query:null};`, `return [];`} {
		d.Auth.Script = Text(untrusted)
		if _, err := Prepare(t.Context(), d, time.Now()); err == nil {
			t.Fatal("接受了错误的脚本输出")
		}
	}
	d.Auth.Script = Text("while (true) {}")
	if _, err := Prepare(t.Context(), d, time.Now()); !errors.Is(err, authInterrupted) {
		t.Fatal(err)
	}
}

func TestWorkspaceCompatibility(t *testing.T) {
	s := Storage{Folder: t.TempDir()}
	old := `{"environments":[{"id":"FFCE3B3C-1FA5-451F-BD3A-368744372903","name":"测试","variables":[
	{"id":"AB313D23-30CE-4F36-9DAF-92EE59EEC283","name":"base","value":"https://example.com","sessionOnly":false}]}],
	"history":[{"id":"49521399-CCF6-4349-AA1D-8020437C0208","date":0,
	"request":{"method":"GET","url":"{{base}}/ping","headers":"X-Legacy: one:two","body":""},
	"environment":"测试","status":200,"milliseconds":20}]}`
	if err := os.WriteFile(s.path(), []byte(old), 0600); err != nil {
		t.Fatal(err)
	}
	w, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	legacy, err := w.OpenHistory(w.History[0].ID)
	if err != nil {
		t.Fatal(err)
	}
	p, err := Prepare(t.Context(), legacy.Request, time.Now())
	if err != nil || p.url.String() != "https://example.com/ping" || p.headers.Get("X-Legacy") != "one:two" {
		t.Fatal(p, err)
	}
	d := NewDraft()
	d.URL = "https://example.com/{host}/ping"
	d.Variables = map[string]string{"host": "example", "token": "directory-private-key"}
	d.Auth = Auth{Mode: "hmac", Name: "directory-api-key", Secret: Text("{token}")}
	id := NewID()
	w.Requests().Requests = append(w.Requests().Requests, SavedRequest{ID: id, Name: "已保存的接口", Draft: d})
	w.History = append(w.History, NewHistory(d, nil, time.Now()))
	if err := s.Save(w); err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(s.path())
	if err != nil || strings.Contains(string(raw), "directory-private-key") || strings.Contains(string(raw), "directory-api-key") {
		t.Fatal("工作区包含明文认证值", err)
	}
	reopened, err := s.Load()
	if err != nil {
		t.Fatal(err)
	}
	if got := reopened.Directory.Requests[0].Draft; value(got.Auth.Secret) != "{token}" || got.Variables["token"] != "directory-private-key" {
		t.Fatal("认证信息未读回")
	}
	if got := reopened.History[1].Request; got.Auth.Secret != nil || got.Variables["token"] != "" {
		t.Fatal("历史未清除凭证")
	}
	key, err := os.ReadFile(s.keyFile())
	if err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(s.keyFile())
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatal("密钥文件权限错误", err)
	}
	locked := Storage{Folder: t.TempDir()}
	if err := os.WriteFile(locked.path(), raw, 0600); err != nil {
		t.Fatal(err)
	}
	w, err = locked.Load()
	if err != nil || len(w.EncryptedCredentials) == 0 || w.Directory.Requests[0].ID != id {
		t.Fatal("旧工作区无法浏览", err)
	}
	if err := locked.Save(w); err == nil {
		t.Fatal("锁定的工作区能被覆盖")
	}
	if _, err := locked.Migrate(make([]byte, 32)); err == nil {
		t.Fatal("迁移错误的密钥竟成功")
	}
	if _, err := locked.Migrate(key); err != nil {
		t.Fatal(err)
	}
	reopened, err = locked.Load()
	if err != nil || reopened.Directory.Requests[0].Draft.Auth.Name != "directory-api-key" {
		t.Fatal("认证迁移未读回", err)
	}
}

func TestResponseAndCancel(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/slow":
			<-r.Context().Done()
		case "/redirect":
			http.Redirect(w, r, "/json", http.StatusFound)
		case "/large":
			w.Header().Set("Content-Type", "text/plain")
			fmt.Fprint(w, strings.Repeat("a", responseLimit+4))
		default:
			w.Header().Set("Content-Type", "application/json")
			json.NewEncoder(w).Encode(map[string]any{"reason": []any{map[string]int{"port": 80}, map[string]string{"port": "443"}}})
		}
	}))
	defer server.Close()
	send := func(ctx context.Context, path string, route *Route, redirects bool) (Response, error) {
		d := NewDraft()
		d.URL = server.URL + path
		d.Route = route
		d.FollowsRedirects = redirects
		if path == "/json" {
			d.Projection = ".reason[]?.port"
		}
		p, err := Prepare(ctx, d, time.Now())
		if err != nil {
			return Response{}, err
		}
		return p.Send(ctx)
	}
	r, err := send(t.Context(), "/json", nil, false)
	if err != nil || value(r.Extracted) != "80\n443" {
		t.Fatal(r, err)
	}
	r, err = send(t.Context(), "/large", nil, false)
	if err != nil || !r.Truncated || r.ByteCount != responseLimit {
		t.Fatal("截断大小错误", err)
	}
	for _, mode := range []bool{false, true} {
		r, err = send(t.Context(), "/redirect", nil, mode)
		want := 302
		if mode {
			want = 200
		}
		if err != nil || r.Status != want {
			t.Fatal(r.Status, err)
		}
	}
	u, _ := url.Parse(server.URL)
	d := NewDraft()
	d.URL = "http://example.test:" + u.Port() + "/json"
	d.Route = &Route{Resolve: "example.test:" + u.Port() + ":127.0.0.1", NoProxy: "example.test"}
	d.Projection = ".reason[]?.port"
	p, err := Prepare(t.Context(), d, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	r, err = p.Send(t.Context())
	if err != nil || value(r.Extracted) != "80\n443" {
		t.Fatal(r, err)
	}
	ctx, cancel := context.WithTimeout(t.Context(), 80*time.Millisecond)
	defer cancel()
	_, err = send(ctx, "/slow", nil, false)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatal(err)
	}
	if _, err := Project(".reason[]?.port", `{"reason":null}`); err != nil {
		t.Fatal(err)
	}
}
