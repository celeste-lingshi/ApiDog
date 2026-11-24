# ApiDog 签名认证

## 签名与字段位置

HMAC-SHA256 是用共享密钥为消息计算认证码的标准做法。字段拼接顺序、编码、放置位置和有效时间由接口提供方定义。

「HMAC-SHA256 签名」方式按给出的约定，把 apikey、securekey、uri 和秒级 timestamp 用下划线连接，再用 securekey 计算 HMAC-SHA256，输出去掉等号填充的 URL 安全 Base64。默认把展开后的 URL 路径作为 uri，包括开头的斜杠和 URL 编码。可以手动指定用于签名的 URI。timestamp 固定写入 URL 查询项，apikey 和 sign 默认也在查询项里，另可选请求头或 JSON 正文。securekey 留作本地计算输入。

Bearer Token 和 Basic 使用 Authorization 请求头。API Key 可以按接口约定放入查询、请求头或 JSON 正文。

## 自定义脚本

在认证里选择「自定义 JavaScript」。按名称和值添加输入，脚本可读取 inputs、request 和 timestamp。request 包含 method、url、uri、query、headers、body，内容已经替换请求变量、尚未加入认证输出。uri 是编码后的路径，query 是保留顺序和重复项的名称值列表。timestamp 是字符串形式的秒级时间戳。

脚本同步返回一个对象。headers 和 query 内填名称到字符串的映射。body 内填要合并到 JSON 对象的字段。键名与手动字段重复时会报错，保持原请求输入。生成器可调用 crypto.hmacSHA256Base64URL(secret, message)、crypto.hmacSHA256Hex(secret, message)、crypto.sha256Hex(message) 和 crypto.base64(text)。

下面这段脚本对应内置 HMAC 的默认行为。在输入栏添加 apikey 和 securekey 两项。

```js
const message = [inputs.apikey, inputs.securekey, request.uri, timestamp].join("_");
return {
  query: {
    apikey: inputs.apikey,
    timestamp,
    sign: crypto.hmacSHA256Base64URL(inputs.securekey, message)
  }
};
```

脚本在独立的 JavaScriptCore 进程运行。JavaScriptCore 是系统提供的 JavaScript 引擎，脚本能调用标准 JavaScript 和上述函数。没有网络、文件、Shell 或系统命令接口。脚本超时会结束当前计算。预览、复制和发送均基于同一请求构建逻辑，复制和发送时重新生成时间相关字段。

认证密钥和脚本输入值只保留在当前运行中。历史保存字段名和脚本，请把密钥填在输入栏。复制的 cURL 包含本次实际生成的认证字段。
