#!/bin/zsh
# =====================================================================
# Claude 单窗口切号 (macOS 版) —— 对应 Windows 的 claude-switch.ps1
#
# 它改的是「默认登录态」：不设 CLAUDE_CONFIG_DIR 时用的那个账号。
#   mac 上登录令牌存在「钥匙串」(service=Claude Code-credentials)，
#   而不是 Windows/Linux 的 ~/.claude/.credentials.json 文件，
#   所以这里用系统自带 security 读写钥匙串。
#
# 注意：
#   - 切换后需「重启 claude / 新开 VSCode 窗口」才生效；已开着的会话不受影响。
#   - 切换后首次访问，macOS 可能弹一次「允许 claude 读取钥匙串」，点允许即可。
#   - 想多个账号「同时并行」用，请改用 claude-env-launcher.command（多环境，更稳）。
#   - 切换前会自动把当前账号快照到 profiles/_切换前自动备份，防丢。
# =====================================================================
export LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8   # 防 C.UTF-8 之类无效 locale 导致多字节解析错
umask 077                                     # 新建的令牌文件/目录默认仅本人可读 (600/700)

ROOT="$(cd "$(dirname "$0")" && pwd)"
PROFILES="$ROOT/profiles"
HOME_CLAUDE_JSON="$HOME/.claude.json"
KC_SVC="Claude Code-credentials"
KC_ACCT="$(id -un)"
mkdir -p "$PROFILES"

# ---------------- osascript 弹窗辅助（转义在 heredoc 外先算好）----------------
msg() {
  local m="${1//\"/\\\"}"
  osascript >/dev/null 2>&1 <<EOF
display dialog "$m" buttons {"好"} default button 1
EOF
}
ask_text() {
  local p="${1//\"/\\\"}"; local a="${2//\"/\\\"}"
  osascript 2>/dev/null <<EOF
try
  return text returned of (display dialog "$p" default answer "$a")
on error
  return ""
end try
EOF
}
ask_buttons() {
  local prompt="$1"; shift
  local btns=""; local b
  for b in "$@"; do btns+="\"${b//\"/\\\"}\", "; done
  btns="${btns%, }"
  local p="${prompt//\"/\\\"}"
  osascript 2>/dev/null <<EOF
try
  return button returned of (display dialog "$p" buttons {$btns} default button 1)
on error
  return ""
end try
EOF
}
choose_from() {
  local prompt="$1"; shift
  local items=""; local o
  for o in "$@"; do items+="\"${o//\"/\\\"}\", "; done
  items="${items%, }"
  local p="${prompt//\"/\\\"}"
  osascript 2>/dev/null <<EOF
set r to choose from list {$items} with prompt "$p"
if r is false then
  return ""
else
  return item 1 of r
end if
EOF
}

# ---------------- 数据辅助 ----------------
cur_cred()  { security find-generic-password -s "$KC_SVC" -w 2>/dev/null; }
cur_oauth() { plutil -extract oauthAccount json -o - "$HOME_CLAUDE_JSON" 2>/dev/null; }
cur_email() { plutil -extract oauthAccount.emailAddress raw -o - "$HOME_CLAUDE_JSON" 2>/dev/null; }
prof_email(){ plutil -extract oauthAccount.emailAddress raw -o - "$1/oauthAccount.json" 2>/dev/null; }

# ---------------- 账号档加密（openssl AES-256-CBC / PBKDF2-SHA256，口令保护）----------------
# 格式与 Windows 端一致（openssl 标准 Salted__），跨平台可互解。
ask_pass() {  # 隐藏输入的口令框；取消返回空
  local p="${1//\"/\\\"}"
  osascript 2>/dev/null <<EOF
try
  return text returned of (display dialog "$p" default answer "" with hidden answer)
on error
  return ""
end try
EOF
}
enc_to()  { openssl enc -aes-256-cbc -pbkdf2 -md sha256 -iter 200000 -salt -pass "pass:$3" -in "$1" -out "$2" 2>/dev/null; }
dec_cat() { openssl enc -d -aes-256-cbc -pbkdf2 -md sha256 -iter 200000 -pass "pass:$2" -in "$1" 2>/dev/null; }
valid_cred() {  # 校验解密结果像不像真凭据（错口令可能解出垃圾且 openssl 不报错）
  case "$1" in (\{*claudeAiOauth*accessToken*) return 0 ;; esac
  return 1
}

write_profile() {  # $1=pdir $2=cred $3=oauth；问是否加密；成功0
  local enc; enc="$(ask_buttons "加密保存此账号档？（加密=令牌不留明文，需设口令）" "加密" "不加密")"
  [ -z "$enc" ] && return 1
  local pp=""
  if [ "$enc" = "加密" ]; then
    pp="$(ask_pass "设置加密口令（务必记住，丢失则无法恢复）：")"; [ -z "$pp" ] && return 1
    local pp2; pp2="$(ask_pass "再次输入确认：")"
    [ "$pp" != "$pp2" ] && { msg "两次口令不一致。"; return 1; }
  fi
  if [ -n "$pp" ]; then
    local tmp tenc; tmp="$(mktemp)"; tenc="$(mktemp)"; print -r -- "$2" > "$tmp"
    enc_to "$tmp" "$tenc" "$pp"; local rc=$?; rm -f "$tmp"
    [ $rc -ne 0 ] && { rm -f "$tenc"; msg "加密失败。"; return 1; }
    mkdir -p "$1"; print -r -- "$3" > "$1/oauthAccount.json"
    rm -f "$1/credentials.json"; mv "$tenc" "$1/credentials.json.enc"; chmod 600 "$1/credentials.json.enc"
  else
    mkdir -p "$1"; print -r -- "$3" > "$1/oauthAccount.json"
    rm -f "$1/credentials.json.enc"; print -r -- "$2" > "$1/credentials.json"; chmod 600 "$1/credentials.json"
  fi
  return 0
}
read_profile_cred() {  # $1=pdir -> stdout=令牌JSON；加密则弹口令；失败返回空
  if [ -f "$1/credentials.json.enc" ]; then
    local pp; pp="$(ask_pass "账号档已加密，输入口令解锁：")"; [ -z "$pp" ] && return 1
    local out; out="$(dec_cat "$1/credentials.json.enc" "$pp")"
    valid_cred "$out" || return 1
    print -r -- "$out"
  elif [ -f "$1/credentials.json" ]; then
    cat "$1/credentials.json"
  else
    return 1
  fi
}

set_oauth() {  # $1=oauthAccount.json -> 只把这一字段合并进 ~/.claude.json
  { [ -f "$1" ] && [ -f "$HOME_CLAUDE_JSON" ] && command -v python3 >/dev/null 2>&1; } || return 0
  local tmp; tmp="$(mktemp)"
  if python3 - "$HOME_CLAUDE_JSON" "$1" "$tmp" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
m["oauthAccount"] = json.load(open(sys.argv[2]))
json.dump(m, open(sys.argv[3], "w"), ensure_ascii=False, indent=2)
PY
  then mv "$tmp" "$HOME_CLAUDE_JSON"; else rm -f "$tmp"; fi
}

# 切换前备份当前账号：令牌进钥匙串(无明文)，非密的 oauth 进文件，便于一键恢复
backup_current() {
  local c; c="$(cur_cred)"; [ -z "$c" ] && return 0
  security add-generic-password -U -a "$KC_ACCT" -s "$KC_SVC (前一个)" -w "$c" 2>/dev/null
  local o; o="$(cur_oauth)"; mkdir -p "$PROFILES/.switch_backup"
  [ -n "$o" ] && print -r -- "$o" > "$PROFILES/.switch_backup/oauthAccount.json"
}
restore_backup() {
  local c; c="$(security find-generic-password -s "$KC_SVC (前一个)" -w 2>/dev/null)"
  [ -z "$c" ] && { msg "没有可恢复的「切换前账号」备份。"; return; }
  security add-generic-password -U -a "$KC_ACCT" -s "$KC_SVC" -w "$c" 2>/dev/null
  set_oauth "$PROFILES/.switch_backup/oauthAccount.json"
  msg "已恢复到「切换前的账号」。请重启 claude / 新开窗口生效。"
}

save_current() {  # 存当前默认账号为命名账号档（可加密）
  if [ -z "$(cur_oauth)" ] || [ -z "$(cur_cred)" ]; then msg "当前默认账号未登录，无可保存。"; return; fi
  local email; email="$(cur_email)"
  local name; name="$(ask_text "账号档命名（便于辨认）：" "$email")"
  [ -z "$name" ] && return; name="${name//\//_}"
  local pdir="$PROFILES/$name"
  if [ -d "$pdir" ]; then
    local c; c="$(ask_buttons "账号档【$name】已存在，覆盖？" "取消" "覆盖")"
    [ "$c" != "覆盖" ] && return
  fi
  if write_profile "$pdir" "$(cur_cred)" "$(cur_oauth)"; then
    msg "已保存账号档【$name】（$email）。"
  else
    [ ! -e "$pdir/credentials.json" ] && [ ! -e "$pdir/credentials.json.enc" ] && rm -rf "$pdir"
  fi
}

switch_to() {  # $1=profile名：写回默认登录态
  local pdir="$PROFILES/$1"
  local cred; cred="$(read_profile_cred "$pdir")"
  [ -z "$cred" ] && { msg "账号档【$1】不完整，或口令错误。"; return; }
  backup_current                                   # 先备份当前（令牌进钥匙串，无明文）
  if ! security add-generic-password -U -a "$KC_ACCT" -s "$KC_SVC" -w "$cred" 2>/dev/null; then
    msg "写入钥匙串失败，未切换。"; return
  fi
  set_oauth "$pdir/oauthAccount.json"
  local em; em="$(prof_email "$pdir")"
  msg "已切换默认账号为【$1】（$em）。

请重启 claude / 新开 VSCode 窗口生效；已开着的会话不受影响。
首次访问若弹「允许 claude 读取钥匙串」，点允许即可。"
}

# ---------------- 主循环 ----------------
while true; do
  cur="$(cur_email)"; [ -z "$cur" ] && cur="未登录"
  rows=(); pnames=(); pd=""
  for pd in "$PROFILES"/*(/N); do
    pn="${pd:t}"
    pe="$(prof_email "$pd")"; [ -z "$pe" ] && pe="?"
    lock=""; [ -f "$pd/credentials.json.enc" ] && lock="🔒"
    rows+=("↪ 切到：$lock$pn  〔$pe〕")
    pnames+=("$pn")
  done
  rows+=("💾 保存当前账号为账号档…")
  security find-generic-password -s "$KC_SVC (前一个)" >/dev/null 2>&1 && rows+=("↩ 恢复切换前的账号")

  choice="$(choose_from "当前默认账号：$cur　·　选要切到的账号档（或保存当前）" "${rows[@]}")"
  [ -z "$choice" ] && exit 0
  if [ "$choice" = "💾 保存当前账号为账号档…" ]; then save_current; continue; fi
  if [ "$choice" = "↩ 恢复切换前的账号" ]; then restore_backup; continue; fi

  sel=""; i=1
  for r in "${rows[@]}"; do
    if [ "$r" = "$choice" ]; then sel="${pnames[$i]}"; break; fi
    ((i++))
  done
  [ -z "$sel" ] && continue

  c="$(ask_buttons "切换默认账号到【$sel】？（会先自动备份当前账号）" "取消" "切换")"
  [ "$c" = "切换" ] && switch_to "$sel"
done
