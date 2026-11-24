package apidog

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
	"unicode"
)

type Field struct {
	ID    string  `json:"id"`
	Name  string  `json:"name"`
	Value *string `json:"value,omitempty"`
}

type Auth struct {
	Mode               string  `json:"mode"`
	Name               string  `json:"name"`
	Secret             *string `json:"secret,omitempty"`
	Placement          string  `json:"placement,omitempty"`
	SigningURI         string  `json:"signingURI,omitempty"`
	SigningKeyField    string  `json:"signingKeyField,omitempty"`
	SigningKeyInput    string  `json:"signingKeyInput,omitempty"`
	SigningSecretInput string  `json:"signingSecretInput,omitempty"`
	Script             *string `json:"script,omitempty"`
	ScriptInputs       []Field `json:"scriptInputs,omitempty"`
}

type Route struct {
	Resolve string `json:"resolve,omitempty"`
	NoProxy string `json:"noProxy,omitempty"`
}

type Draft struct {
	Method           string            `json:"method"`
	URL              string            `json:"url"`
	Headers          []Field           `json:"headers"`
	Query            []Field           `json:"query"`
	Variables        map[string]string `json:"variables"`
	Auth             Auth              `json:"auth"`
	Body             *string           `json:"body,omitempty"`
	FollowsRedirects bool              `json:"followsRedirects"`
	Route            *Route            `json:"route,omitempty"`
	Projection       string            `json:"projection,omitempty"`
}

func NewID() string {
	var b [16]byte
	rand.Read(b[:])
	b[6] = b[6]&15 | 64
	b[8] = b[8]&63 | 128
	return fmt.Sprintf("%X-%X-%X-%X-%X", b[:4], b[4:6], b[6:8], b[8:10], b[10:])
}

func Text(s string) *string { return &s }

func value(s *string) string {
	if s == nil {
		return ""
	}
	return *s
}

func field(name string, v *string) Field { return Field{NewID(), name, v} }

func NewDraft() Draft {
	return Draft{Method: "GET", Auth: Auth{Mode: "none"}, Headers: []Field{}, Query: []Field{}, Variables: map[string]string{}}
}

func (d *Draft) UnmarshalJSON(data []byte) error {
	type plain Draft
	fields := struct {
		*plain
		Headers json.RawMessage `json:"headers"`
	}{plain: (*plain)(d)}
	*d = NewDraft()
	if err := json.Unmarshal(data, &fields); err != nil {
		return err
	}
	if len(fields.Headers) == 0 {
		return nil
	}
	if fields.Headers[0] != '"' {
		if err := json.Unmarshal(fields.Headers, &d.Headers); err != nil {
			return err
		}
		if d.Headers == nil {
			d.Headers = []Field{}
		}
		return nil
	}
	var old string
	if err := json.Unmarshal(fields.Headers, &old); err != nil {
		return err
	}
	for _, line := range strings.FieldsFunc(old, func(r rune) bool { return r == '\r' || r == '\n' }) {
		name, payload, ok := strings.Cut(line, ":")
		item := field(strings.TrimSpace(name), Text(strings.TrimSpace(payload)))
		if !ok {
			item = field(line, Text(""))
		}
		d.Headers = append(d.Headers, item)
	}
	if value(d.Body) == "" {
		d.Body = nil
	}
	return nil
}

var placeholder = regexp.MustCompile(`\{\{\s*([A-Za-z_][A-Za-z0-9_.-]*)\s*\}\}|\{([A-Za-z_][A-Za-z0-9_.-]*)\}`)
var headerName = regexp.MustCompile("^[!#$%&'*+.^_\\x60|~0-9A-Za-z-]+$")
var methods = []string{"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"}

func supportedMethod(method string) bool {
	for _, m := range methods {
		if m == method {
			return true
		}
	}
	return false
}

func (d Draft) allowsBody() bool { return d.Method != "GET" && d.Method != "HEAD" }

type missingVariable string

func (e missingVariable) Error() string { return "请在变量页填写「" + string(e) + "」。" }

func (d Draft) expand(s string, encodePath bool) (string, error) {
	var result strings.Builder
	offset := 0
	for _, match := range placeholder.FindAllStringSubmatchIndex(s, -1) {
		single := match[2] < 0
		start, end := match[2], match[3]
		if single {
			start, end = match[4], match[5]
		}
		name := s[start:end]
		replacement := d.Variables[name]
		if replacement == "" {
			return "", missingVariable(name)
		}
		if single && encodePath {
			replacement = percentEncode(replacement)
		}
		result.WriteString(s[offset:match[0]])
		result.WriteString(replacement)
		offset = match[1]
	}
	result.WriteString(s[offset:])
	return result.String(), nil
}

func (d Draft) VariableNames() []string {
	inputs := []string{d.URL}
	for _, list := range [][]Field{d.Query, d.Headers} {
		for _, f := range list {
			inputs = append(inputs, f.Name, value(f.Value))
		}
	}
	if d.Auth.Mode != "none" {
		inputs = append(inputs, d.Auth.Name, value(d.Auth.Secret), d.Auth.SigningURI)
	}
	if d.Auth.Mode == "script" {
		for _, f := range d.Auth.ScriptInputs {
			inputs = append(inputs, value(f.Value))
		}
	}
	if d.Route != nil {
		inputs = append(inputs, d.Route.Resolve, d.Route.NoProxy)
	}
	if d.allowsBody() {
		inputs = append(inputs, value(d.Body))
	}
	names := []string{}
	seen := map[string]bool{}
	for _, input := range inputs {
		for _, parts := range placeholder.FindAllStringSubmatch(input, -1) {
			name := parts[1]
			if name == "" {
				name = parts[2]
			}
			if !seen[name] {
				seen[name] = true
				names = append(names, name)
			}
		}
	}
	return names
}

func percentEncode(s string) string { return strings.ReplaceAll(url.QueryEscape(s), "+", "%20") }

func validHeader(name, value string) bool {
	return headerName.MatchString(name) && !strings.ContainsFunc(value, func(c rune) bool { return c != '\t' && unicode.IsControl(c) })
}

func parseURL(address string) (*url.URL, error) {
	u, err := url.Parse(address)
	if err != nil || u.Hostname() == "" || u.User != nil || (u.Scheme != "http" && u.Scheme != "https") {
		return nil, errors.New("请输入完整的 HTTP 或 HTTPS 地址。")
	}
	return u, nil
}

func queryFields(raw string) ([]Field, error) {
	fields := []Field{}
	if raw == "" {
		return fields, nil
	}
	for _, item := range strings.Split(raw, "&") {
		name, payload, hasValue := strings.Cut(item, "=")
		decoded, err := url.PathUnescape(name)
		if err != nil {
			return nil, err
		}
		var v *string
		if hasValue {
			text, err := url.PathUnescape(payload)
			if err != nil {
				return nil, err
			}
			v = Text(text)
		}
		fields = append(fields, field(decoded, v))
	}
	return fields, nil
}

func appendQuery(u *url.URL, parts ...string) {
	if u.RawQuery != "" {
		parts = append([]string{u.RawQuery}, parts...)
	}
	u.RawQuery = strings.Join(parts, "&")
}

func (d Draft) resolveRoute(u *url.URL) (*Route, error) {
	if d.Route == nil {
		return nil, nil
	}
	resolve, err := d.expand(d.Route.Resolve, false)
	if err != nil {
		return nil, err
	}
	noProxy, err := d.expand(d.Route.NoProxy, false)
	if err != nil {
		return nil, err
	}
	if strings.ContainsFunc(noProxy, unicode.IsControl) {
		return nil, errors.New("直连主机列表不能包含控制字符。")
	}
	if resolve == "" && noProxy == "" {
		return nil, nil
	}
	if resolve != "" {
		parts := strings.SplitN(resolve, ":", 3)
		if len(parts) != 3 {
			return nil, invalidResolve
		}
		port, err := strconv.Atoi(parts[1])
		ip := strings.TrimPrefix(strings.TrimSuffix(parts[2], "]"), "[")
		addr, addressErr := netip.ParseAddr(ip)
		bracketed := strings.HasPrefix(parts[2], "[") && strings.HasSuffix(parts[2], "]")
		if err != nil || port < 1 || port > 65535 || addressErr != nil || addr.Zone() != "" || bracketed != addr.Is6() {
			return nil, invalidResolve
		}
		expected := u.Port()
		if expected == "" {
			expected = "80"
			if u.Scheme == "https" {
				expected = "443"
			}
		}
		if !strings.EqualFold(parts[0], u.Hostname()) || strconv.Itoa(port) != expected {
			return nil, errors.New("指定解析的域名和端口须与请求 URL 一致。")
		}
	}
	return &Route{Resolve: resolve, NoProxy: noProxy}, nil
}

var invalidResolve = errors.New("指定解析需要填写「域名:端口:IP」，IPv6 地址用方括号括起。")

type prepared struct {
	method     string
	url        *url.URL
	headers    http.Header
	body       *string
	route      *Route
	projection string
	redirects  bool
}

func Prepare(ctx context.Context, d Draft, at time.Time) (*prepared, error) {
	if !supportedMethod(d.Method) {
		return nil, fmt.Errorf("不支持请求方法 %s。", d.Method)
	}
	address, err := d.expand(d.URL, true)
	if err != nil {
		return nil, err
	}
	u, err := parseURL(strings.TrimSpace(address))
	if err != nil {
		return nil, err
	}
	u.Fragment = ""
	for _, f := range d.Query {
		if strings.TrimSpace(f.Name) == "" {
			continue
		}
		name, err := d.expand(f.Name, false)
		if err != nil {
			return nil, err
		}
		item := percentEncode(name)
		if f.Value != nil {
			v, err := d.expand(*f.Value, false)
			if err != nil {
				return nil, err
			}
			item += "=" + percentEncode(v)
		}
		appendQuery(u, item)
	}
	route, err := d.resolveRoute(u)
	if err != nil {
		return nil, err
	}
	if d.Projection != "" {
		if _, err := parseProjection(d.Projection); err != nil {
			return nil, err
		}
	}
	p := &prepared{d.Method, u, make(http.Header), nil, route, d.Projection, d.FollowsRedirects}
	for i, f := range d.Headers {
		name, err := d.expand(f.Name, false)
		if err != nil {
			return nil, err
		}
		v, err := d.expand(value(f.Value), false)
		if err != nil {
			return nil, err
		}
		name, v = strings.Trim(name, " \t"), strings.Trim(v, " \t")
		if name == "" && v == "" {
			continue
		}
		if !validHeader(name, v) {
			return nil, fmt.Errorf("请检查第 %d 行请求头的名称和值。", i+1)
		}
		p.headers.Add(name, v)
	}
	if d.allowsBody() && d.Body != nil {
		body, err := d.expand(*d.Body, false)
		if err != nil {
			return nil, err
		}
		p.body = &body
	}
	if d.Auth.Mode != "" && d.Auth.Mode != "none" {
		fields, err := d.authenticate(ctx, p, strconv.FormatInt(at.Unix(), 10))
		if err != nil {
			return nil, err
		}
		if err := p.addAuth(fields, d.allowsBody()); err != nil {
			return nil, err
		}
	}
	if p.body != nil {
		if strings.ContainsRune(*p.body, 0) {
			return nil, errors.New("请求体不能包含 NUL 字符。")
		}
		if _, ok := p.headers["Content-Type"]; !ok {
			contentType := "text/plain; charset=utf-8"
			if json.Valid([]byte(*p.body)) {
				contentType = "application/json"
			}
			p.headers.Set("Content-Type", contentType)
		}
	}
	return p, nil
}

type generated struct {
	Headers map[string]string `json:"headers,omitempty"`
	Query   map[string]string `json:"query,omitempty"`
	Body    map[string]any    `json:"body,omitempty"`
}

func (a Auth) location() string {
	if a.Placement != "" {
		return a.Placement
	}
	if a.Mode == "hmac" {
		return "query"
	}
	return "header"
}

func mismatch(name string) error {
	return fmt.Errorf("生成的认证字段「%s」与当前请求重复。", name)
}

func (d Draft) authenticate(ctx context.Context, p *prepared, timestamp string) (generated, error) {
	a := d.Auth
	g := generated{map[string]string{}, map[string]string{}, map[string]any{}}
	path := p.url.EscapedPath()
	if path == "" {
		path = "/"
	}
	if a.Mode == "script" {
		return runAuth(ctx, d, p, path, timestamp)
	}
	name, err := d.expand(a.Name, false)
	if err != nil {
		return g, err
	}
	secret, err := d.expand(value(a.Secret), false)
	if err != nil {
		return g, err
	}
	name = strings.Trim(name, " \t")
	if a.Secret == nil {
		return g, invalidAuth
	}
	place := func(name, secret string) error {
		switch a.location() {
		case "header":
			g.Headers[name] = secret
		case "query":
			g.Query[name] = secret
		case "body":
			g.Body[name] = secret
		default:
			return invalidAuth
		}
		return nil
	}
	switch a.Mode {
	case "bearer":
		if secret == "" {
			return g, invalidAuth
		}
		g.Headers["Authorization"] = "Bearer " + secret
	case "basic":
		if name == "" || strings.Contains(name, ":") {
			return g, invalidAuth
		}
		g.Headers["Authorization"] = "Basic " + base64.StdEncoding.EncodeToString([]byte(name+":"+secret))
	case "apiKey":
		if name == "" || secret == "" {
			return g, invalidAuth
		}
		return g, place(name, secret)
	case "hmac":
		if name == "" || secret == "" {
			return g, invalidAuth
		}
		if uri := strings.TrimSpace(a.SigningURI); uri != "" {
			path, err = d.expand(uri, false)
			if err != nil {
				return g, err
			}
		}
		keyField := strings.TrimSpace(a.SigningKeyField)
		if keyField == "" {
			keyField = "apikey"
		}
		reserved := keyField
		if a.location() == "header" {
			reserved = strings.ToLower(reserved)
		}
		if reserved == "timestamp" || reserved == "sign" {
			return g, mismatch(keyField)
		}
		g.Query["timestamp"] = timestamp
		if err := place(keyField, name); err != nil {
			return g, err
		}
		return g, place("sign", base64.RawURLEncoding.EncodeToString(sign(secret, strings.Join([]string{name, secret, path, timestamp}, "_"))))
	default:
		return g, invalidAuth
	}
	return g, nil
}

var invalidAuth = errors.New("请检查认证的字段和值。")
var invalidAuthBody = errors.New("请使用允许正文的请求方法，并提供一个 JSON 对象正文。")

func sign(secret, message string) []byte {
	mac := hmac.New(sha256.New, []byte(secret))
	mac.Write([]byte(message))
	return mac.Sum(nil)
}

func sortedKeys[V any](m map[string]V) []string {
	keys := make([]string, 0, len(m))
	for key := range m {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	return keys
}

func (p *prepared) addAuth(g generated, allowsBody bool) error {
	for _, name := range sortedKeys(g.Headers) {
		v := g.Headers[name]
		if !validHeader(name, v) {
			return invalidAuth
		}
		if _, exists := p.headers[http.CanonicalHeaderKey(name)]; exists {
			return mismatch(name)
		}
		p.headers.Set(name, v)
	}
	if len(g.Query) > 0 {
		items, err := queryFields(p.url.RawQuery)
		if err != nil {
			return err
		}
		for _, name := range sortedKeys(g.Query) {
			if name == "" {
				return invalidAuthOutput
			}
			for _, f := range items {
				if f.Name == name {
					return mismatch(name)
				}
			}
			appendQuery(p.url, percentEncode(name)+"="+percentEncode(g.Query[name]))
		}
	}
	if len(g.Body) > 0 {
		if !allowsBody {
			return invalidAuthBody
		}
		object := map[string]any{}
		if body := strings.TrimSpace(value(p.body)); body != "" {
			if json.Unmarshal([]byte(body), &object) != nil || object == nil {
				return invalidAuthBody
			}
		}
		for name, v := range g.Body {
			if name == "" {
				return invalidAuthOutput
			}
			if _, exists := object[name]; exists {
				return mismatch(name)
			}
			object[name] = v
		}
		data, err := marshalJSON(object)
		if err != nil {
			return err
		}
		p.body = Text(string(data))
	}
	return nil
}

func (d Draft) redacted() Draft {
	result := d
	result.Variables = make(map[string]string, len(d.Variables))
	for k, v := range d.Variables {
		result.Variables[k] = v
	}
	protected := []string{value(d.Auth.Secret)}
	if d.Auth.Mode == "hmac" {
		protected = append(protected, d.Auth.Name)
		result.Auth.Name = ""
	}
	result.Auth.Secret = nil
	result.Auth.ScriptInputs = append([]Field(nil), d.Auth.ScriptInputs...)
	for i, f := range d.Auth.ScriptInputs {
		protected = append(protected, value(f.Value))
		result.Auth.ScriptInputs[i].Value = nil
	}
	for _, s := range protected {
		for _, parts := range placeholder.FindAllStringSubmatch(s, -1) {
			delete(result.Variables, parts[1]+parts[2])
		}
	}
	return result
}
