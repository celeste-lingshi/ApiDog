package apidog

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/dop251/goja"
)

const AuthWorkerArgument = "--apidog-auth-worker"
const AuthExample = "if (!inputs.token) throw new Error(\"请填写 token\");\nreturn { headers: { Authorization: \"Bearer \" + inputs.token } };"
const maxAuthInput = 512 * 1024
const maxAuthOutput = 64 * 1024

var invalidAuthOutput = errors.New("脚本需要返回对象，headers 和 query 的值须为字符串，body 须为 JSON 对象。")
var authSize = errors.New("脚本输入或输出超过大小限制。")
var authUnavailable = errors.New("无法启动或读取认证脚本进程。")
var authInterrupted = errors.New("认证脚本运行超时或异常中止。")

func marshalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	if err := encoder.Encode(v); err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(buf.Bytes(), []byte{'\n'}), nil
}

type authContext struct {
	Method  string            `json:"method"`
	URL     string            `json:"url"`
	URI     string            `json:"uri"`
	Query   []map[string]any  `json:"query"`
	Headers map[string]string `json:"headers"`
	Body    string            `json:"body"`
}
type authInput struct {
	Source    string            `json:"source"`
	Inputs    map[string]string `json:"inputs"`
	Request   authContext       `json:"request"`
	Timestamp string            `json:"timestamp"`
}
type authResult struct {
	Fields json.RawMessage `json:"fields,omitempty"`
	Error  string          `json:"error,omitempty"`
}

func runAuth(ctx context.Context, d Draft, p *prepared, path, timestamp string) (generated, error) {
	var result generated
	headers := map[string]string{}
	for k, v := range p.headers {
		headers[k] = strings.Join(v, ",")
	}
	query := []map[string]any{}
	items, err := queryFields(p.url.RawQuery)
	if err != nil {
		return result, err
	}
	for _, f := range items {
		var v any
		if f.Value != nil {
			v = *f.Value
		}
		query = append(query, map[string]any{"name": f.Name, "value": v})
	}
	inputs := map[string]string{}
	for _, f := range d.Auth.ScriptInputs {
		name := strings.TrimSpace(f.Name)
		if name == "" && value(f.Value) == "" {
			continue
		}
		if _, seen := inputs[name]; name == "" || seen {
			return result, errors.New("请为每项脚本输入填写唯一的名称。")
		}
		if value(f.Value) == "" {
			return result, fmt.Errorf("请填写脚本输入「%s」。", name)
		}
		v, err := d.expand(*f.Value, false)
		if err != nil {
			return result, err
		}
		inputs[name] = v
	}
	source := AuthExample
	if d.Auth.Script != nil {
		source = *d.Auth.Script
	}
	data, err := marshalJSON(authInput{source, inputs, authContext{p.method, p.url.String(), path, query, headers, value(p.body)}, timestamp})
	if err != nil {
		return result, err
	}
	if len(data) > maxAuthInput {
		return result, authSize
	}
	executable, err := os.Executable()
	if err != nil {
		return result, authUnavailable
	}
	workerCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	command := exec.CommandContext(workerCtx, executable, AuthWorkerArgument)
	command.Env = []string{}
	command.Stdin = bytes.NewReader(data)
	output, err := command.Output()
	if ctx.Err() != nil {
		return result, ctx.Err()
	}
	if workerCtx.Err() != nil {
		return result, authInterrupted
	}
	if err != nil {
		return result, authUnavailable
	}
	var reply authResult
	if json.Unmarshal(output, &reply) != nil {
		return result, authUnavailable
	}
	if reply.Error != "" {
		return result, fmt.Errorf("认证脚本：%s", reply.Error)
	}
	if err := json.Unmarshal(reply.Fields, &result); err != nil {
		return result, invalidAuthOutput
	}
	return result, nil
}

func RunAuthWorker(in io.Reader, out io.Writer) {
	var req authInput
	var reply authResult
	data, err := io.ReadAll(io.LimitReader(in, maxAuthInput+1))
	switch {
	case err != nil:
		reply.Error = authUnavailable.Error()
	case len(data) > maxAuthInput:
		reply.Error = authSize.Error()
	case json.Unmarshal(data, &req) != nil:
		reply.Error = authUnavailable.Error()
	default:
		reply.Fields, err = req.evaluate()
		if err != nil {
			reply.Error = err.Error()
		}
	}
	json.NewEncoder(out).Encode(reply)
}

func (a authInput) evaluate() ([]byte, error) {
	vm := goja.New()
	crypto := map[string]any{
		"hmacSHA256Base64URL": func(secret, message string) string {
			return base64.RawURLEncoding.EncodeToString(sign(secret, message))
		},
		"hmacSHA256Hex": func(secret, message string) string { return hex.EncodeToString(sign(secret, message)) },
		"sha256Hex": func(message string) string {
			digest := sha256.Sum256([]byte(message))
			return hex.EncodeToString(digest[:])
		},
		"base64": func(message string) string { return base64.StdEncoding.EncodeToString([]byte(message)) },
	}
	requestData, err := marshalJSON(a.Request)
	if err != nil {
		return nil, err
	}
	var context map[string]any
	if err := json.Unmarshal(requestData, &context); err != nil {
		return nil, err
	}
	// 按参数传入请求上下文，脚本仅能使用 JavaScript 和列出的加密函数。
	for name, v := range map[string]any{"inputs": a.Inputs, "request": context, "timestamp": a.Timestamp, "crypto": crypto} {
		if err := vm.Set(name, v); err != nil {
			return nil, err
		}
	}
	result, err := vm.RunString("(function(inputs,request,timestamp,crypto){\n\"use strict\";\n" + a.Source + "\n})(inputs,request,timestamp,crypto)")
	if err != nil {
		return nil, scriptMessage(err)
	}
	if _, ok := result.(*goja.Object); !ok {
		return nil, invalidAuthOutput
	}
	object := vm.Get("JSON").ToObject(vm)
	stringify, ok := goja.AssertFunction(object.Get("stringify"))
	if !ok {
		return nil, invalidAuthOutput
	}
	serialized, err := stringify(object, result)
	if err != nil {
		return nil, scriptMessage(err)
	}
	raw := []byte(serialized.String())
	if len(raw) > maxAuthOutput {
		return nil, authSize
	}
	var fields map[string]any
	if json.Unmarshal(raw, &fields) != nil || fields == nil {
		return nil, invalidAuthOutput
	}
	for k, v := range fields {
		obj, ok := v.(map[string]any)
		if !ok {
			return nil, invalidAuthOutput
		}
		switch k {
		case "headers", "query":
			for _, value := range obj {
				if _, ok := value.(string); !ok {
					return nil, invalidAuthOutput
				}
			}
		case "body":
		default:
			return nil, invalidAuthOutput
		}
	}
	return raw, nil
}

func scriptMessage(err error) error {
	text := []rune(err.Error())
	if len(text) > 240 {
		text = text[:240]
	}
	return errors.New(string(text))
}
