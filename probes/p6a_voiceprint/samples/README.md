# P6a 录音样本放这里(已 gitignore,不入库)

命名:`<人>_<语言>_<序号>.<wav|m4a|mp3|aiff|caf|flac>`
- 本人必须叫 `me`:`me_zh_1.m4a` … `me_zh_5.m4a`、`me_en_1.m4a` …
- 他人任意取名:`laoba_zh_1.m4a`、`tongshi_en_1.m4a`、`podcast1_en_1.mp3`
- 每段 ≥20s(低于 15s 会警告);中英各 5 段本人 + 2–3 个他人若干段
- 录音用 QuickTime / 语音备忘录都行,格式不限(探针自动转 16k 单声道)

跑法(在 probes/p6a_voiceprint/ 下):
    swift run -c release p6a matrix samples/
    swift run -c release p6a decay samples/me_zh_1.m4a
