package apidog

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestAuthenticatedRedirect(t *testing.T) {
	var destinationHits atomic.Int32
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		destinationHits.Add(1)
		fmt.Fprint(w, "外站")
	}))
	defer destination.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/external":
			http.Redirect(w, r, destination.URL+"/receive?opaque=hidden", http.StatusFound)
		case "/local":
			http.Redirect(w, r, "/receive", http.StatusTemporaryRedirect)
		case "/to-get":
			http.Redirect(w, r, "/receive", http.StatusFound)
		default:
			if r.Header.Get("X-API-Key") != "example-only" {
				http.Error(w, "缺少示例认证头", http.StatusUnauthorized)
				return
			}
			fmt.Fprint(w, r.Method)
		}
	}))
	defer source.Close()

	for _, transport := range []string{"Go", "系统 cURL"} {
		t.Run(transport, func(t *testing.T) {
			d := NewDraft()
			d.URL = source.URL + "/external"
			d.Method = http.MethodPost
			d.Body = Text("example payload")
			d.FollowsRedirects = true
			d.Auth = Auth{Mode: "apiKey", Name: "X-API-Key", Secret: Text("example-only")}
			if transport == "系统 cURL" {
				d.Route = &Route{NoProxy: "127.0.0.1"}
			}
			send := func(d Draft) (Response, CurlPreview) {
				t.Helper()
				ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
				defer cancel()
				p, err := Prepare(ctx, d, time.Now())
				if err != nil {
					t.Fatal(err)
				}
				response, err := p.Send(ctx)
				if err != nil {
					t.Fatal(err)
				}
				return response, p.Preview()
			}

			before := destinationHits.Load()
			response, command := send(d)
			if response.Status != http.StatusFound || response.RedirectBlocked != destination.URL+"/receive" ||
				destinationHits.Load() != before || !command.FirstHopOnly || strings.Contains(command.Command, "--location") {
				t.Fatalf("认证跳转或导出行为有误：%+v", response)
			}

			d.URL = source.URL + "/local"
			response, _ = send(d)
			if response.Status != http.StatusOK || response.RedirectBlocked != "" || response.Body != "POST" {
				t.Fatalf("同源 307 应保留 POST：%+v", response)
			}

			d.URL = source.URL + "/to-get"
			response, _ = send(d)
			if response.Status != http.StatusOK || response.Body != "GET" {
				t.Fatalf("同源 302 应把普通 POST 转为 GET：%+v", response)
			}

			d.URL = source.URL + "/external?sign=example-only"
			d.Auth = Auth{Mode: "none"}
			response, _ = send(d)
			if response.Status != http.StatusFound || destinationHits.Load() != before {
				t.Fatal("直接写在地址栏的签名应保护")
			}

			d.URL = source.URL + "/external"
			response, command = send(d)
			if response.Body != "外站" || destinationHits.Load() != before+1 ||
				command.FirstHopOnly || !strings.Contains(command.Command, "--location") {
				t.Fatal("公开请求应该正常跟随、导出跨站跳转")
			}
		})
	}
}

func TestRawQueryEncoding(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprint(w, r.URL.RawQuery)
	}))
	defer server.Close()
	d := NewDraft()
	d.URL = server.URL + "/example?flag&repeat=1&repeat=2&encoded=%2f&text=中文 a+b&literal=100%&path=a/b"
	const expected = "flag&repeat=1&repeat=2&encoded=%2f&text=%E4%B8%AD%E6%96%87%20a+b&literal=100%25&path=a/b"

	p, err := Prepare(t.Context(), d, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	res, err := p.Send(t.Context())
	if err != nil || res.Status != http.StatusOK || res.Body != expected {
		t.Fatalf("收到的查询不正确：%+v, %v", res, err)
	}
	if !strings.Contains(p.Command(), "?"+expected) {
		t.Fatal("导出的 cURL 应使用编码后的地址")
	}
}
