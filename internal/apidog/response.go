package apidog

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"
)

const responseLimit = 256 * 1024

type Response struct {
	Status          int     `json:"status"`
	Headers         string  `json:"headers"`
	Body            string  `json:"body"`
	ByteCount       int     `json:"byteCount"`
	Truncated       bool    `json:"truncated"`
	Extracted       *string `json:"extracted,omitempty"`
	ExtractionError string  `json:"extractionError,omitempty"`
	RedirectBlocked string  `json:"redirectBlocked,omitempty"`
}

type step struct {
	key             string
	array, optional bool
}

var projectionKey = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*$`)
var invalidProjection = errors.New("提取表达式支持简单字段路径，例如 .reason[]?.port。")
var invalidProjectionType = errors.New("响应字段类型与提取表达式不匹配。")

func parseProjection(expression string) ([]step, error) {
	if expression == "." {
		return nil, nil
	}
	if !strings.HasPrefix(expression, ".") {
		return nil, invalidProjection
	}
	steps := []step{}
	for _, part := range strings.Split(expression[1:], ".") {
		key, optional := strings.CutSuffix(part, "?")
		key, array := strings.CutSuffix(key, "[]")
		if !projectionKey.MatchString(key) {
			return nil, invalidProjection
		}
		steps = append(steps, step{key, array, optional})
	}
	return steps, nil
}

func Project(expression, body string) (string, error) {
	steps, err := parseProjection(expression)
	if err != nil {
		return "", err
	}
	var root any
	decode := json.NewDecoder(strings.NewReader(body))
	decode.UseNumber()
	if !json.Valid([]byte(body)) || decode.Decode(&root) != nil {
		return "", errors.New("只有完整的 JSON 响应可以提取字段。")
	}
	values := []any{root}
	for _, s := range steps {
		next := []any{}
		for _, item := range values {
			var v any
			switch obj := item.(type) {
			case map[string]any:
				v = obj[s.key]
			case nil:
			default:
				if s.optional {
					continue
				}
				return "", invalidProjectionType
			}
			if !s.array {
				next = append(next, v)
				continue
			}
			switch obj := v.(type) {
			case []any:
				next = append(next, obj...)
			case map[string]any:
				for _, k := range sortedKeys(obj) {
					next = append(next, obj[k])
				}
			default:
				if !s.optional {
					return "", invalidProjectionType
				}
			}
		}
		values = next
	}
	lines := []string{}
	for _, v := range values {
		if text, ok := v.(string); ok {
			lines = append(lines, text)
			continue
		}
		data, err := marshalJSON(v)
		if err != nil {
			return "", err
		}
		lines = append(lines, string(data))
	}
	return strings.Join(lines, "\n"), nil
}

func (p *prepared) Send(ctx context.Context) (Response, error) {
	var r Response
	var err error
	if p.route != nil {
		r, err = p.sendRouted(ctx)
	} else {
		r, err = p.sendHTTP(ctx)
	}
	if err == nil && p.projection != "" {
		if r.Truncated {
			r.ExtractionError = "响应已截断，请到正文页查看已收到的内容。"
		} else {
			text, err := Project(p.projection, r.Body)
			if err != nil {
				r.ExtractionError = err.Error()
			} else {
				r.Extracted = Text(text)
			}
		}
	}
	return r, err
}

func (p *prepared) sendHTTP(ctx context.Context) (Response, error) {
	var blocked string
	client := http.Client{CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if !p.redirects {
			return http.ErrUseLastResponse
		}
		if p.authenticated && !canFollowAuthenticated(p.url, req.URL) {
			blocked = redirectDisplay(req.URL)
			return http.ErrUseLastResponse
		}
		if len(via) >= 20 {
			return errors.New("重定向次数超过限制。")
		}
		if req.URL.Scheme != "http" && req.URL.Scheme != "https" {
			return errors.New("重定向目标须为 HTTP 或 HTTPS。")
		}
		return nil
	}}
	var reader io.Reader
	if p.body != nil {
		reader = strings.NewReader(*p.body)
	}
	request, err := http.NewRequestWithContext(ctx, p.method, p.url.String(), reader)
	if err != nil {
		return Response{}, err
	}
	request.Header = p.headers.Clone()
	if host := request.Header.Get("Host"); host != "" {
		request.Host = host
		request.Header.Del("Host")
	}
	response, err := client.Do(request)
	if err != nil {
		if ctx.Err() != nil {
			return Response{}, ctx.Err()
		}
		var target interface{ Unwrap() error }
		if errors.As(err, &target) && target.Unwrap() != nil {
			return Response{}, fmt.Errorf("发送请求失败：%s", target.Unwrap())
		}
		return Response{}, errors.New("发送请求失败。")
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, responseLimit+1))
	if err != nil {
		return Response{}, err
	}
	lines := []string{}
	for _, key := range sortedKeys(response.Header) {
		lines = append(lines, key+": "+strings.Join(response.Header[key], ", "))
	}
	result := makeResponse(response.StatusCode, strings.Join(lines, "\n"), response.Header.Get("Content-Type"), data)
	result.RedirectBlocked = blocked
	return result, nil
}

func (p *prepared) sendRouted(ctx context.Context) (Response, error) {
	if !p.redirects || !p.authenticated {
		return p.sendRoutedOnce(ctx)
	}
	hop := *p
	hop.redirects = false
	for redirects := 0; ; redirects++ {
		result, err := hop.sendRoutedOnce(ctx)
		if err != nil {
			return result, err
		}
		location := redirectLocation(result)
		if location == "" {
			return result, nil
		}
		next, err := hop.url.Parse(location)
		if err != nil {
			return Response{}, errors.New("跳转目标地址无效。")
		}
		if !canFollowAuthenticated(p.url, next) {
			result.RedirectBlocked = redirectDisplay(next)
			return result, nil
		}
		if redirects >= 19 {
			return Response{}, errors.New("重定向次数超过限制。")
		}
		next.RawQuery = normalizeRawQuery(next.RawQuery)
		next.Fragment = ""
		hop.url = next
		switch result.Status {
		case http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther:
			if hop.body != nil {
				// cURL 只把隐式 POST 改为 GET，显式方法仍沿用原设置。
				if hop.method == http.MethodPost {
					hop.method = http.MethodGet
				}
				hop.body = nil
				hop.headers = hop.headers.Clone()
				hop.headers.Del("Content-Length")
			}
		}
	}
}

func canFollowAuthenticated(origin, target *url.URL) bool {
	port := func(u *url.URL) string {
		if explicit := u.Port(); explicit != "" {
			return explicit
		}
		if u.Scheme == "https" {
			return "443"
		}
		return "80"
	}
	return target.User == nil && origin.Scheme == target.Scheme &&
		strings.EqualFold(origin.Hostname(), target.Hostname()) && port(origin) == port(target)
}

func redirectDisplay(target *url.URL) string {
	summary := url.URL{Scheme: target.Scheme, Host: target.Host, Path: target.Path, RawPath: target.RawPath}
	if summary.Host == "" {
		return "外部地址"
	}
	return summary.String()
}

func redirectLocation(response Response) string {
	switch response.Status {
	case http.StatusMovedPermanently, http.StatusFound, http.StatusSeeOther,
		http.StatusTemporaryRedirect, http.StatusPermanentRedirect:
		for _, line := range strings.Split(response.Headers, "\n") {
			name, value, _ := strings.Cut(line, ":")
			if strings.EqualFold(name, "Location") {
				return strings.TrimSpace(value)
			}
		}
	}
	return ""
}

func (p *prepared) sendRoutedOnce(ctx context.Context) (Response, error) {
	folder, err := os.MkdirTemp("", "apidog-response-")
	if err != nil {
		return Response{}, err
	}
	defer os.RemoveAll(folder)
	headers := filepath.Join(folder, "headers")
	options := [][]string{{"--silent"}, {"--proto", "=http,https"}, {"--proto-redir", "=http,https"},
		{"--max-time", "30"}, {"--max-redirs", "20"}, {"--dump-header", headers}}
	options = append(options, p.curlOptions()...)
	var config strings.Builder
	quote := strings.NewReplacer("\\", "\\\\", "\"", "\\\"", "\t", "\\t", "\r", "\\r", "\n", "\\n", "\v", "\\v")
	for _, opt := range options {
		config.WriteString(strings.TrimPrefix(opt[0], "--"))
		if len(opt) > 1 {
			config.WriteString(" = \"" + quote.Replace(opt[1]) + "\"")
		}
		config.WriteByte('\n')
	}
	// 请求参数通过标准输入传递，进程参数里没有密钥。
	cmd := exec.CommandContext(ctx, "/usr/bin/curl", "--disable", "--config", "-")
	cmd.Stdin = strings.NewReader(config.String())
	cmd.Env = []string{}
	for _, key := range []string{"http_proxy", "https_proxy", "all_proxy", "no_proxy", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"} {
		if v, ok := os.LookupEnv(key); ok {
			cmd.Env = append(cmd.Env, key+"="+v)
		}
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return Response{}, err
	}
	if err = cmd.Start(); err != nil {
		return Response{}, err
	}
	limit := int64(responseLimit + 1)
	if p.method == "HEAD" {
		limit = 0
		defer stdout.Close()
	}
	var data []byte
	if limit > 0 {
		data, err = io.ReadAll(io.LimitReader(stdout, limit))
	} else {
		_, err = io.Copy(io.Discard, stdout)
	}
	if len(data) > responseLimit || err != nil {
		cmd.Process.Kill()
	}
	wait := cmd.Wait()
	if ctx.Err() != nil {
		return Response{}, ctx.Err()
	}
	if err != nil {
		return Response{}, err
	}
	if wait != nil && len(data) <= responseLimit {
		var exit *exec.ExitError
		if errors.As(wait, &exit) {
			return Response{}, fmt.Errorf("系统 cURL 发送失败，退出码 %d。", exit.ExitCode())
		}
		return Response{}, wait
	}
	f, err := os.Open(headers)
	if err != nil {
		return Response{}, errors.New("服务端没有返回 HTTP 响应。")
	}
	defer f.Close()
	raw, err := io.ReadAll(io.LimitReader(f, 512*1024))
	if err != nil {
		return Response{}, err
	}
	blocks := strings.Split(strings.ReplaceAll(string(raw), "\r\n", "\n"), "\n\n")
	for i := len(blocks) - 1; i >= 0; i-- {
		if !strings.HasPrefix(blocks[i], "HTTP/") {
			continue
		}
		lines := strings.Split(blocks[i], "\n")
		fields := strings.Fields(lines[0])
		if len(fields) < 2 {
			break
		}
		status, err := strconv.Atoi(fields[1])
		if err != nil {
			break
		}
		mime := ""
		for _, line := range lines[1:] {
			name, v, _ := strings.Cut(line, ":")
			if strings.EqualFold(name, "Content-Type") {
				mime = strings.TrimSpace(v)
				break
			}
		}
		return makeResponse(status, strings.Join(lines[1:], "\n"), mime, data), nil
	}
	return Response{}, errors.New("服务端没有返回 HTTP 响应。")
}

func makeResponse(status int, headers, mime string, data []byte) Response {
	r := Response{Status: status, Headers: headers, Truncated: len(data) > responseLimit}
	if r.Truncated {
		data = data[:responseLimit]
	}
	r.ByteCount = len(data)
	if len(data) == 0 {
		return r
	}
	if !r.Truncated && json.Valid(data) {
		var content any
		decoder := json.NewDecoder(bytes.NewReader(data))
		decoder.UseNumber()
		if decoder.Decode(&content) == nil {
			raw, _ := marshalJSON(content)
			var pretty bytes.Buffer
			if json.Indent(&pretty, raw, "", "  ") == nil {
				r.Body = pretty.String()
				return r
			}
		}
	}
	mime = strings.ToLower(strings.TrimSpace(strings.Split(mime, ";")[0]))
	if strings.HasPrefix(mime, "text/") || strings.Contains(mime, "json") || strings.Contains(mime, "xml") || (mime == "" && utf8.Valid(data)) {
		r.Body = strings.ToValidUTF8(string(data), "�")
	} else {
		if mime == "" {
			mime = "未知类型"
		}
		r.Body = fmt.Sprintf("二进制响应（%s，%d 字节）", mime, len(data))
	}
	return r
}
