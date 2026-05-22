import std/[os, strutils, httpclient, json]
import parsetoml
import types

const systemPrompt = """你是日语学习助手。用户的每条消息都是一句日语，你必须严格按下面三段格式输出，每段以分隔符行开头，分隔符行单独占一行；不得有任何额外文字、Markdown、引号或对格式本身的说明。

###TRANSLATION###
（在此写出整句的自然中文翻译，简洁，一行）
###VOCABULARY###
（逐词列出；每行格式："词形（假名读音）— 词性·中文释义"；汉字词必须给假名；助词、副词、连词等均需列出；按句中出现顺序）
###GRAMMAR###
（列出本句的关键语法点与句型；每行格式："句型/词缀 — 用法说明"；只列与本句直接相关者，3-6 条为宜）"""

type
  Config* = object
    apiKey*: string
    model*: string
    baseUrl*: string

proc loadConfig*(): Config =
  let cfgPath = getHomeDir() / ".config" / "manabu" / "config.toml"
  if not fileExists(cfgPath):
    stderr.writeLine("错误：找不到配置文件 " & cfgPath)
    stderr.writeLine("请创建该文件并填入 api_key = \"sk-...\"")
    quit(1)
  let t = parsetoml.parseFile(cfgPath)
  if not t.hasKey("api_key"):
    stderr.writeLine("错误：config.toml 中缺少 api_key 字段")
    quit(1)
  let apiKey = t["api_key"].getStr()
  if apiKey.strip() == "":
    stderr.writeLine("错误：api_key 不能为空")
    quit(1)
  Config(
    apiKey: apiKey,
    model: if t.hasKey("model"): t["model"].getStr() else: "deepseek-chat",
    baseUrl: if t.hasKey("base_url"): t["base_url"].getStr() else: "https://api.deepseek.com"
  )

proc parseResponse*(raw: string): Annotation =
  let tMarker = "###TRANSLATION###"
  let vMarker = "###VOCABULARY###"
  let gMarker = "###GRAMMAR###"

  let ti = raw.find(tMarker)
  let vi = raw.find(vMarker)
  let gi = raw.find(gMarker)

  if ti < 0 or vi < 0 or gi < 0:
    return Annotation(
      translation: raw.strip(),
      vocabulary: "(模型未返回词汇段)",
      grammar: "(模型未返回文法段)"
    )

  let translation = raw[ti + tMarker.len ..< vi].strip()
  let vocabulary  = raw[vi + vMarker.len ..< gi].strip()
  let grammar     = raw[gi + gMarker.len ..< raw.len].strip()
  Annotation(translation: translation, vocabulary: vocabulary, grammar: grammar)

proc requestAnnotation*(cfg: Config, sentence: string): Annotation =
  let messages = %* [
    {"role": "system", "content": systemPrompt},
    {"role": "user",   "content": sentence}
  ]
  let body = %* {
    "model": cfg.model,
    "messages": messages,
    "temperature": 0.3,
    "max_tokens": 4096
  }

  var client = newHttpClient(timeout = 30_000)
  client.headers = newHttpHeaders({
    "Content-Type": "application/json",
    "Authorization": "Bearer " & cfg.apiKey
  })
  try:
    let resp = client.post(cfg.baseUrl & "/chat/completions", body = $body)
    if resp.status != "200 OK":
      return Annotation(
        translation: "API 错误：" & resp.status,
        vocabulary: resp.body[0 .. min(200, resp.body.len-1)],
        grammar: ""
      )
    let j = parseJson(resp.body)
    let content = j["choices"][0]["message"]["content"].getStr()
    result = parseResponse(content)
  except CatchableError as e:
    result = Annotation(
      translation: "请求失败：" & e.msg,
      vocabulary: "",
      grammar: ""
    )
  finally:
    client.close()
