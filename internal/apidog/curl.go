package apidog

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

type CurlPreview struct {
	Command      string `json:"command"`
	FirstHopOnly bool   `json:"firstHopOnly,omitempty"`
}

func Preview(ctx context.Context, d Draft) (CurlPreview, error) {
	if err := ctx.Err(); err != nil {
		return CurlPreview{}, err
	}
	p, err := Prepare(ctx, d, time.Now())
	if err != nil {
		return CurlPreview{}, err
	}
	if err := ctx.Err(); err != nil {
		return CurlPreview{}, err
	}
	return p.Preview(), nil
}

func (p *prepared) Preview() CurlPreview {
	return CurlPreview{Command: p.Command(), FirstHopOnly: p.redirects && p.authenticated}
}

func (p *prepared) Command() string {
	options := p.curlOptions()
	if p.projection != "" {
		options = append([][]string{options[0], {"--silent"}, {"--show-error"}}, options[1:]...)
	}
	lines := []string{}
	for _, option := range options {
		line := option[0]
		if len(option) > 1 {
			line += " " + shellQuote(option[1])
		}
		lines = append(lines, line)
	}
	out := "curl " + strings.Join(lines, " \\\n  ")
	if p.projection != "" {
		out += " |\n  jq -r " + shellQuote(p.projection)
	}
	return out
}

func shellQuote(value string) string { return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'" }

func (p *prepared) curlOptions() [][]string {
	options := [][]string{{"--globoff"}}
	if p.redirects && !p.authenticated {
		options = append(options, []string{"--location"})
	}
	if p.route != nil {
		if p.route.Resolve != "" {
			options = append(options, []string{"--resolve", p.route.Resolve})
		}
		if p.route.NoProxy != "" {
			options = append(options, []string{"--noproxy", p.route.NoProxy})
		}
	}
	if p.method == "HEAD" {
		options = append(options, []string{"--head"})
	} else if p.method != "POST" || p.body == nil {
		options = append(options, []string{"--request", p.method})
	}
	options = append(options, []string{"--url", p.url.String()})
	for _, name := range sortedKeys(p.headers) {
		v := strings.Join(p.headers[name], ",")
		header := name + ";"
		if v != "" {
			header = name + ": " + v
		}
		options = append(options, []string{"--header", header})
	}
	if p.body != nil {
		options = append(options, []string{"--data-raw", *p.body})
	}
	return options
}

var shellExpression = errors.New("命令含 Shell 表达式。请粘贴已展开的请求命令。")
var badQuoting = errors.New("命令里的引号或转义不完整，或包含暂不支持的转义。")
var unsupportedPipeline = errors.New("响应管道支持 jq -r 和简单字段路径，例如 .reason[]?.port。")
var fileReference = errors.New("导入仅接收文本，不会读取文件引用。")
var unsupportedBody = errors.New("请求方法和正文选项不兼容，GET 或 HEAD 无法携带正文。")
var invalidCredentials = errors.New("请使用明确的一种认证方式，Basic 需要用户名和密码。")

func isShellName(r rune) bool {
	return r == '_' || r >= 'A' && r <= 'Z' || r >= 'a' && r <= 'z' || r >= '0' && r <= '9'
}

func tokenize(text string, substitutions map[string]string, pipe bool) ([]string, []string, error) {
	runes := []rune(text)
	var words, before []string
	var word strings.Builder
	var mode rune
	started := false
	add := func() {
		if started {
			words = append(words, word.String())
			word.Reset()
			started = false
		}
	}
	for i := 0; i < len(runes); i++ {
		c := runes[i]
		switch mode {
		case '\'':
			if c == '\'' {
				mode = 0
			} else {
				word.WriteRune(c)
			}
			continue
		case '$':
			if c == '\'' {
				mode = 0
				continue
			}
			if c != '\\' {
				word.WriteRune(c)
				continue
			}
			i++
			if i == len(runes) {
				return nil, nil, badQuoting
			}
			switch escaped := runes[i]; escaped {
			case 'n':
				word.WriteByte('\n')
			case 'r':
				word.WriteByte('\r')
			case 't':
				word.WriteByte('\t')
			case '\\', '\'', '"':
				word.WriteRune(escaped)
			default:
				return nil, nil, badQuoting
			}
			continue
		}
		if c == '\\' {
			i++
			if i == len(runes) {
				return nil, nil, badQuoting
			}
			escaped := runes[i]
			if escaped == '\r' && i+1 < len(runes) && runes[i+1] == '\n' {
				i++
				continue
			}
			if escaped == '\n' {
				continue
			}
			if mode == '"' && !strings.ContainsRune("\"\\$", escaped) {
				word.WriteByte('\\')
			}
			word.WriteRune(escaped)
			started = true
			continue
		}
		if mode == '"' {
			switch c {
			case '"':
				mode = 0
			case '\x60':
				return nil, nil, shellExpression
			case '$':
				if substitutions == nil || i+1 == len(runes) {
					return nil, nil, shellExpression
				}
				braced := runes[i+1] == '{'
				if braced {
					i++
				}
				start := i + 1
				for i+1 < len(runes) && isShellName(runes[i+1]) {
					i++
				}
				name := string(runes[start : i+1])
				if braced {
					i++
					if i >= len(runes) || runes[i] != '}' {
						return nil, nil, shellExpression
					}
				}
				v, known := substitutions[name]
				if !known {
					return nil, nil, fmt.Errorf("无法静态展开 Shell 变量「%s」。", name)
				}
				word.WriteString(v)
			default:
				word.WriteRune(c)
			}
			continue
		}
		if unicode.IsSpace(c) {
			add()
			continue
		}
		if c == '|' && pipe {
			if before != nil || !started && len(words) == 0 {
				return nil, nil, unsupportedPipeline
			}
			add()
			before, words = words, nil
			continue
		}
		started = true
		switch c {
		case '\'', '"':
			mode = c
		case '$':
			i++
			if i >= len(runes) || runes[i] != '\'' {
				return nil, nil, shellExpression
			}
			mode = '$'
		case '\x60', ';', '|', '&', '>', '<', '(', ')':
			return nil, nil, shellExpression
		default:
			word.WriteRune(c)
		}
	}
	if mode != 0 {
		return nil, nil, badQuoting
	}
	add()
	if before != nil {
		if words == nil {
			words = []string{}
		}
		return before, words, nil
	}
	return words, nil, nil
}

var assignmentStart = regexp.MustCompile(`^[A-Za-z_][A-Za-z0-9_]*=`)

func ImportCurl(text string) (Draft, error) {
	text = strings.TrimSpace(text)
	if assignmentStart.MatchString(text) {
		return importSigned(text)
	}
	return parseCurl(text, nil, nil)
}

func parseCurl(text string, substitutions, variables map[string]string) (Draft, error) {
	d := NewDraft()
	args, pipe, err := tokenize(text, substitutions, true)
	if err != nil {
		return d, err
	}
	if len(args) == 0 || args[0] != "curl" {
		return d, errors.New("请粘贴以 curl 开头的命令。")
	}
	templates := args
	if len(variables) > 0 {
		replacements := map[string]string{}
		for k, v := range substitutions {
			replacements[k] = v
		}
		for k, v := range variables {
			replacements[k] = "{{" + k + "}}"
			d.Variables[k] = v
		}
		templates, _, err = tokenize(text, replacements, true)
		if err != nil {
			return d, err
		}
	}
	if pipe != nil {
		if len(pipe) != 3 || pipe[0] != "jq" || (pipe[1] != "-r" && pipe[1] != "--raw-output") {
			return d, unsupportedPipeline
		}
		if _, err := parseProjection(pipe[2]); err != nil {
			return d, err
		}
		d.Projection = pipe[2]
	}
	var address, templateAddress, method string
	var data []string
	var route Route
	var auth *Auth
	var get, head, jsonBody, endOptions, hasAddress bool
	setAddress := func(literal, template string) error {
		if hasAddress {
			return errors.New("一次只能导入一个请求地址。")
		}
		address, templateAddress, hasAddress = literal, template, true
		return nil
	}
	addHeader := func(name, text string) { d.Headers = append(d.Headers, field(name, Text(text))) }
	hasHeader := func(name string) bool {
		for _, h := range d.Headers {
			if strings.EqualFold(h.Name, name) {
				return true
			}
		}
		return false
	}
	for i := 1; i < len(args); i++ {
		arg, tpl := args[i], templates[i]
		if endOptions || !strings.HasPrefix(arg, "-") {
			if err := setAddress(arg, tpl); err != nil {
				return d, err
			}
			continue
		}
		if arg == "--" {
			endOptions = true
			continue
		}
		opt, inline, attached := strings.Cut(arg, "=")
		tmplValue := ""
		if attached {
			_, tmplValue, _ = strings.Cut(tpl, "=")
		}
		if len(arg) > 2 && arg[0] == '-' && strings.ContainsRune("XHduAbe", rune(arg[1])) {
			opt, inline, attached, tmplValue = arg[:2], arg[2:], true, tpl[2:]
		}
		pair := func() (string, string, error) {
			if attached {
				attached = false
				return inline, tmplValue, nil
			}
			i++
			if i >= len(args) {
				return "", "", fmt.Errorf("cURL 参数 %s 缺少值。", opt)
			}
			return args[i], templates[i], nil
		}
		switch opt {
		case "--url", "-X", "--request", "-H", "--header", "-d", "--data", "--data-ascii", "--data-raw", "--data-binary", "--json",
			"--data-urlencode", "-u", "--user", "--oauth2-bearer", "-b", "--cookie", "-A", "--user-agent", "-e", "--referer", "--resolve", "--noproxy":
			v, t, err := pair()
			if err != nil {
				return d, err
			}
			switch opt {
			case "--url":
				if err := setAddress(v, t); err != nil {
					return d, err
				}
			case "-X", "--request":
				method = strings.ToUpper(v)
				if !supportedMethod(method) {
					return d, fmt.Errorf("暂不支持请求方法 %s。", method)
				}
			case "-H", "--header":
				name, payload, hasColon := strings.Cut(v, ":")
				if !hasColon && strings.HasSuffix(v, ";") {
					addHeader(strings.TrimSuffix(v, ";"), "")
					break
				}
				if !hasColon || strings.TrimSpace(payload) == "" {
					return d, errors.New("请检查 cURL 的请求头。")
				}
				addHeader(strings.TrimSpace(name), strings.TrimSpace(payload))
			case "-d", "--data", "--data-ascii", "--data-raw", "--data-binary", "--json":
				if opt != "--data-raw" && strings.HasPrefix(v, "@") {
					return d, fileReference
				}
				data = append(data, v)
				jsonBody = jsonBody || opt == "--json"
			case "--data-urlencode":
				name, payload, found := strings.Cut(v, "=")
				if found {
					if name != "" {
						name += "="
					}
					data = append(data, name+percentEncode(payload))
				} else {
					if strings.Contains(v, "@") {
						return d, fileReference
					}
					data = append(data, percentEncode(v))
				}
			case "-u", "--user":
				name, secret, found := strings.Cut(v, ":")
				if !found || auth != nil {
					return d, invalidCredentials
				}
				auth = &Auth{Mode: "basic", Name: name, Secret: Text(secret)}
			case "--oauth2-bearer":
				if auth != nil {
					return d, invalidCredentials
				}
				auth = &Auth{Mode: "bearer", Secret: Text(v)}
			case "-b", "--cookie":
				if !strings.Contains(v, "=") {
					return d, fileReference
				}
				addHeader("Cookie", v)
			case "-A", "--user-agent":
				addHeader("User-Agent", v)
			case "-e", "--referer":
				if strings.HasSuffix(v, ";auto") {
					return d, fmt.Errorf("暂不支持 cURL 参数 %s。", opt)
				}
				addHeader("Referer", v)
			case "--resolve":
				if route.Resolve != "" || t == "" {
					return d, invalidResolve
				}
				route.Resolve = t
			case "--noproxy":
				route.NoProxy = t
			}
		case "-I", "--head":
			head = true
		case "-G", "--get":
			get = true
		case "-L", "--location":
			d.FollowsRedirects = true
		case "-g", "--globoff", "--compressed", "--basic", "-s", "-S", "-sS", "-fsS", "-f", "--fail", "--silent", "--show-error":
		default:
			return d, fmt.Errorf("暂不支持 cURL 参数 %s。", opt)
		}
		if attached {
			return d, fmt.Errorf("暂不支持 cURL 参数 %s。", arg)
		}
	}
	u, err := parseURL(address)
	if err != nil {
		return d, errors.New("命令需要一个完整的 HTTP 或 HTTPS 地址。")
	}
	if method != "" {
		d.Method = method
	} else if head {
		d.Method = "HEAD"
	} else if !get && len(data) > 0 {
		d.Method = "POST"
	}
	if head && d.Method != "HEAD" || !get && len(data) > 0 && !d.allowsBody() {
		return d, unsupportedBody
	}
	base := func(v string) string {
		if i := strings.IndexAny(v, "?#"); i >= 0 {
			return v[:i]
		}
		return v
	}
	d.URL = base(address)
	if expanded, err := d.expand(base(templateAddress), true); err == nil && expanded == d.URL {
		d.URL = base(templateAddress)
	}
	d.Query, err = queryFields(u.RawQuery)
	if err != nil {
		return d, errors.New("请对 cURL 的查询字符串做 URL 编码。")
	}
	if len(data) > 0 {
		if get {
			raw := strings.Join(data, "&")
			if strings.ContainsRune(raw, '#') || strings.ContainsFunc(raw, unicode.IsSpace) {
				return d, errors.New("请先对 cURL 的查询字符串做 URL 编码，或使用 --data-urlencode。")
			}
			items, err := queryFields(raw)
			if err != nil {
				return d, err
			}
			d.Query = append(d.Query, items...)
		} else {
			join, contentType := "&", "application/x-www-form-urlencoded"
			if jsonBody {
				join, contentType = "", "application/json"
			}
			d.Body = Text(strings.Join(data, join))
			if !hasHeader("Content-Type") {
				addHeader("Content-Type", contentType)
			}
		}
	}
	if jsonBody && !hasHeader("Accept") {
		addHeader("Accept", "application/json")
	}
	authIndex := func(name string) (int, int) {
		index, count := -1, 0
		for i, h := range d.Headers {
			if strings.EqualFold(h.Name, name) {
				index = i
				count++
			}
		}
		return index, count
	}
	remove := func(i int) { d.Headers = append(d.Headers[:i], d.Headers[i+1:]...) }
	index, count := authIndex("Authorization")
	if auth != nil {
		if count > 0 {
			return d, invalidCredentials
		}
		d.Auth = *auth
	} else if count == 1 {
		scheme, raw, found := strings.Cut(value(d.Headers[index].Value), " ")
		raw = strings.TrimLeft(raw, " ")
		if found && raw != "" {
			switch strings.ToLower(scheme) {
			case "bearer":
				d.Auth = Auth{Mode: "bearer", Secret: Text(raw)}
				remove(index)
			case "basic":
				bytes, e := base64.StdEncoding.DecodeString(raw)
				name, secret, hasColon := strings.Cut(string(bytes), ":")
				if e == nil && utf8.Valid(bytes) && hasColon && name != "" {
					d.Auth = Auth{Mode: "basic", Name: name, Secret: Text(secret)}
					remove(index)
				}
			}
		}
	}
	if d.Auth.Mode == "none" {
		if index, count := authIndex("X-API-Key"); count == 1 && value(d.Headers[index].Value) != "" {
			d.Auth = Auth{Mode: "apiKey", Name: d.Headers[index].Name, Secret: d.Headers[index].Value}
			remove(index)
		}
	}
	if route.Resolve != "" || route.NoProxy != "" {
		d.Route = &route
	}
	if _, err := Prepare(context.Background(), d, time.Now()); err != nil {
		var variable missingVariable
		if !errors.As(err, &variable) {
			return d, err
		}
	}
	return d, nil
}

const identifier = `[A-Za-z_][A-Za-z0-9_]*`
const braced = `\$\{(` + identifier + `)\}`

var curlStart = regexp.MustCompile(`(?m)^[ \t]*curl[ \t]+`)
var continuations = regexp.MustCompile(`\\\r?\n`)
var shellIdentifier = regexp.MustCompile(`^` + identifier + `$`)
var timeAssignment = regexp.MustCompile(`^\$\(\s*date\s+\+%s\s*\)$`)
var signing = regexp.MustCompile(`(?:^|\n)[ \t]*(` + identifier + `)=\$\(\s*printf\s+'%s'\s+"` +
	braced + "_" + braced + "_" + braced + "_" + braced + `"\s*\|\s*openssl\s+dgst\s+-sha256\s+-hmac\s+"\$(?:\{(` +
	identifier + `)\}|(` + identifier + `))"\s+-binary\s*\|\s*openssl\s+base64\s+-A\s*\|\s*tr\s+'/\+'\s+'_-'` +
	`\s*\|\s*tr\s+-d\s+'='\s*\)\s*$`)

var invalidRecipe = errors.New("无法识别签名命令。请使用普通变量赋值、date +%s 和 OpenSSL HMAC-SHA256 写法。")
var invalidRecipeFields = errors.New("签名命令需要在查询中引用 Key、timestamp 和 sign，且每项只出现一次。")

func importSigned(text string) (Draft, error) {
	d := NewDraft()
	start := curlStart.FindStringIndex(text)
	if start == nil {
		return d, invalidRecipe
	}
	prefix := continuations.ReplaceAllString(text[:start[0]], "")
	signMatch := signing.FindStringSubmatchIndex(prefix)
	if signMatch == nil {
		return d, invalidRecipe
	}
	group := func(n int) string {
		a, b := signMatch[2*n], signMatch[2*n+1]
		if a < 0 {
			return ""
		}
		return prefix[a:b]
	}
	signName, keyName, secretName, pathName, timeName := group(1), group(2), group(3), group(4), group(5)
	if group(6)+group(7) != secretName {
		return d, invalidRecipe
	}
	names := map[string]bool{}
	for _, name := range []string{signName, keyName, secretName, pathName, timeName} {
		names[name] = true
	}
	if len(names) != 5 {
		return d, invalidRecipe
	}
	literals := map[string]string{}
	declared := map[string]bool{}
	for _, line := range strings.Split(prefix[:signMatch[0]], "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		name, raw, ok := strings.Cut(line, "=")
		if !ok || !shellIdentifier.MatchString(name) || declared[name] || name == signName {
			return d, invalidRecipe
		}
		declared[name] = true
		if name == timeName {
			if !timeAssignment.MatchString(raw) {
				return d, invalidRecipe
			}
			continue
		}
		words, _, err := tokenize(raw, nil, false)
		if err != nil {
			return d, err
		}
		if len(words) > 1 {
			return d, invalidRecipe
		}
		literals[name] = ""
		if len(words) == 1 {
			literals[name] = words[0]
		}
	}
	if !declared[timeName] || literals[pathName] == "" {
		return d, invalidRecipe
	}
	key := literals[keyName]
	var secret *string
	if v, ok := literals[secretName]; ok {
		secret = Text(v)
	}
	delete(literals, keyName)
	delete(literals, secretName)
	templates := map[string]string{}
	for k, v := range literals {
		templates[k] = v
	}
	marker := NewID()
	keyMarker, timeMarker, signMarker := marker+"-key", marker+"-time", marker+"-sign"
	literals[keyName], literals[timeName], literals[signName] = keyMarker, timeMarker, signMarker
	d, err := parseCurl(text[start[0]:], literals, templates)
	if err != nil {
		return d, err
	}
	if d.Auth.Mode != "none" {
		return d, invalidRecipeFields
	}
	keyField := ""
	for _, f := range d.Query {
		if value(f.Value) == keyMarker {
			keyField = f.Name
			break
		}
	}
	if keyField == "" || keyField == "sign" || keyField == "timestamp" {
		return d, invalidRecipeFields
	}
	expected := map[string]string{keyField: keyMarker, "timestamp": timeMarker, "sign": signMarker}
	remaining := []Field{}
	seen := map[string]bool{}
	for _, f := range d.Query {
		if want, found := expected[f.Name]; found {
			if seen[f.Name] || value(f.Value) != want {
				return d, invalidRecipeFields
			}
			seen[f.Name] = true
		} else {
			remaining = append(remaining, f)
		}
	}
	if len(seen) != len(expected) {
		return d, invalidRecipeFields
	}
	d.Query = remaining
	leftovers := []string{d.URL, value(d.Body), d.Projection}
	if d.Route != nil {
		leftovers = append(leftovers, d.Route.Resolve, d.Route.NoProxy)
	}
	for _, list := range [][]Field{d.Query, d.Headers} {
		for _, f := range list {
			leftovers = append(leftovers, f.Name, value(f.Value))
		}
	}
	for _, v := range leftovers {
		if strings.Contains(v, marker) {
			return d, invalidRecipeFields
		}
	}
	d.Auth = Auth{Mode: "hmac", Name: key, Secret: secret, SigningURI: "{{" + pathName + "}}", SigningKeyField: keyField, SigningKeyInput: keyName, SigningSecretInput: secretName}
	d.Variables = map[string]string{}
	for _, name := range d.VariableNames() {
		if v, ok := templates[name]; ok {
			d.Variables[name] = v
		}
	}
	return d, nil
}
