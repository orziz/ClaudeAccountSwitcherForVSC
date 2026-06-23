#!/bin/zsh
# =====================================================================
# Claude 多账号 · 环境启动台 (macOS 版)
# 与 Windows 版同一机制：
#   每个“环境” = 独立 CLAUDE_CONFIG_DIR（自带 .claude.json/.credentials.json）
#              + 独立 VSCode --user-data-dir（独立进程，环境变量才隔离得开）
# 选环境 → 打开窗口 → 启动一个绑定该账号的独立 VSCode；多个可同时各用各号。
#
# 零安装：界面用系统自带 osascript 弹窗，读 JSON 用系统自带 plutil。
# 首次使用：chmod +x 本文件，然后双击（或终端运行）。
# =====================================================================

ROOT="$(cd "$(dirname "$0")" && pwd)"
ENVS="$ROOT/envs"
PROFILES="$ROOT/profiles"
HOME_CRED="$HOME/.claude/.credentials.json"
HOME_CLAUDE_JSON="$HOME/.claude.json"
mkdir -p "$ENVS"

# ---------------- osascript 弹窗辅助 ----------------
msg() {  # 信息框
  osascript >/dev/null 2>&1 <<EOF
display dialog "${1//\"/\\\"}" buttons {"好"} default button 1
EOF
}
ask_text() {  # 文本输入，返回内容；取消返回空
  osascript 2>/dev/null <<EOF
try
  return text returned of (display dialog "${1//\"/\\\"}" default answer "${2//\"/\\\"}")
on error
  return ""
end try
EOF
}
choose_folder() {  # 选文件夹，返回 POSIX 路径；取消返回空
  osascript 2>/dev/null <<EOF
try
  return POSIX path of (choose folder with prompt "${1//\"/\\\"}")
on error
  return ""
end try
EOF
}
ask_buttons() {  # 提示 + 最多3个按钮，返回按钮文字；取消返回空
  local prompt="$1"; shift
  local btns=""; local b
  for b in "$@"; do btns+="\"${b//\"/\\\"}\", "; done
  btns="${btns%, }"
  osascript 2>/dev/null <<EOF
try
  return button returned of (display dialog "${prompt//\"/\\\"}" buttons {$btns} default button 1)
on error
  return ""
end try
EOF
}
choose_from() {  # 列表单选，返回选中文字；取消返回空
  local prompt="$1"; shift
  local items=""; local o
  for o in "$@"; do items+="\"${o//\"/\\\"}\", "; done
  items="${items%, }"
  osascript 2>/dev/null <<EOF
set r to choose from list {$items} with prompt "${prompt//\"/\\\"}"
if r is false then
  return ""
else
  return item 1 of r
end if
EOF
}

# ---------------- 数据辅助（plutil 读 JSON，系统自带）----------------
find_code() {
  if command -v code >/dev/null 2>&1; then command -v code; return; fi
  local c="/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
  [ -x "$c" ] && echo "$c"
}
env_email() {  # $1=envdir -> 邮箱或空
  plutil -extract oauthAccount.emailAddress raw -o - "$1/.claude.json" 2>/dev/null
}
env_project() {  # $1=envdir -> 默认项目或空
  plutil -extract defaultProject raw -o - "$1/env-meta.json" 2>/dev/null
}

seed_env() {  # $1=envdir $2=凭据源 $3=oauthAccount(JSON文本)
  cp "$2" "$1/.credentials.json"
  printf '{\n  "oauthAccount": %s\n}\n' "$3" > "$1/.claude.json"
}
seed_vscode_settings() {  # $1=vscode-userdata 目录；把常用 VSCode 设置带进来（扩展本就共享，无需处理）
  local src="$HOME/Library/Application Support/Code/User"
  [ -d "$src" ] || return 0
  local dst="$1/User"; mkdir -p "$dst"
  [ -f "$src/settings.json" ]    && cp "$src/settings.json"    "$dst/" 2>/dev/null
  [ -f "$src/keybindings.json" ] && cp "$src/keybindings.json" "$dst/" 2>/dev/null
  [ -d "$src/snippets" ]         && cp -R "$src/snippets"      "$dst/" 2>/dev/null
  return 0
}
create_env() {  # $1=name $2=proj $3=mode(login/current/profile) $4=src
  local envdir="$ENVS/$1"
  mkdir -p "$envdir/vscode-userdata"
  seed_vscode_settings "$envdir/vscode-userdata"
  printf '{"defaultProject":"%s"}\n' "$2" > "$envdir/env-meta.json"
  case "$3" in
    current)
      local oauth; oauth="$(plutil -extract oauthAccount json -o - "$HOME_CLAUDE_JSON" 2>/dev/null)"
      if [ -z "$oauth" ] || [ ! -f "$HOME_CRED" ]; then rm -rf "$envdir"; msg "当前默认账号未登录，无法灌入。"; return 1; fi
      seed_env "$envdir" "$HOME_CRED" "$oauth" ;;
    profile)
      if [ ! -f "$4/credentials.json" ]; then rm -rf "$envdir"; msg "账号档不完整。"; return 1; fi
      seed_env "$envdir" "$4/credentials.json" "$(cat "$4/oauthAccount.json")" ;;
    *) : ;;  # login：留空，开窗后自己 /login
  esac
}
user_locale() {  # 从 ~/.vscode/argv.json 读界面语言（带注释，用 grep 抠）
  local argv="$HOME/.vscode/argv.json"
  [ -f "$argv" ] || return 0
  grep -o '"locale"[[:space:]]*:[[:space:]]*"[^"]*"' "$argv" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/'
}
open_env() {  # $1=name
  local envdir="$ENVS/$1"
  local proj; proj="$(env_project "$envdir")"
  local code; code="$(find_code)"
  if [ -z "$code" ]; then
    msg "找不到 VSCode 的 code 命令。\n请在 VSCode 里运行：Shell Command: Install 'code' command in PATH"
    return
  fi
  mkdir -p "$envdir/vscode-userdata"
  local args=(--user-data-dir "$envdir/vscode-userdata" --new-window)
  local loc; loc="$(user_locale)"
  [ -n "$loc" ] && args+=(--locale "$loc")        # 独立窗口也用你的界面语言
  [ -n "$proj" ] && [ -d "$proj" ] && args+=("$proj")
  CLAUDE_CONFIG_DIR="$envdir" "$code" "${args[@]}"
}

# ---------------- 新建环境流程 ----------------
new_env_flow() {
  local name; name="$(ask_text "环境名（工作 / 外包 / 开源 / 个人）：" "")"
  [ -z "$name" ] && return
  name="${name//\//_}"
  if [ -d "$ENVS/$name" ]; then msg "环境【$name】已存在。"; return; fi
  local proj; proj="$(choose_folder "选环境【$name】默认打开的项目目录（可取消=不设）")"

  local curemail; curemail="$(plutil -extract oauthAccount.emailAddress raw -o - "$HOME_CLAUDE_JSON" 2>/dev/null)"
  local curlabel="用当前登录的号"; [ -n "$curemail" ] && curlabel="用当前登录的号（$curemail）"
  local bind; bind="$(ask_buttons "环境【$name】绑定哪个号？" "现场登录" "$curlabel" "从账号档…")"
  [ -z "$bind" ] && return

  if [ "$bind" = "现场登录" ]; then
    create_env "$name" "$proj" "login" "" && msg "环境【$name】已建好。开窗后在里面 /login 一次。"
  elif [ "$bind" = "从账号档…" ]; then
    local pnames=(); local pd
    for pd in "$PROFILES"/*(/N); do pnames+=("${pd:t}"); done
    if [ ${#pnames} -eq 0 ]; then
      msg "还没有已存账号档，改用现场登录。"
      create_env "$name" "$proj" "login" "" && msg "环境【$name】已建好。开窗后 /login 一次。"
    else
      local pick; pick="$(choose_from "选要灌入的账号档" "${pnames[@]}")"
      [ -z "$pick" ] && return
      create_env "$name" "$proj" "profile" "$PROFILES/$pick" && msg "环境【$name】已建好（已灌入 $pick）。"
    fi
  else
    # 当前登录的号（按钮文字含邮箱，落到 else）
    if [ -z "$curemail" ]; then
      msg "当前默认账号未登录，改用现场登录。"
      create_env "$name" "$proj" "login" "" && msg "环境【$name】已建好。"
    else
      create_env "$name" "$proj" "current" "" && msg "环境【$name】已建好（已灌入 $curemail）。"
    fi
  fi
}

# ---------------- 主循环 ----------------
while true; do
  rows=(); names=(); d=""
  for d in "$ENVS"/*(/N); do
    n="${d:t}"
    email="$(env_email "$d")"; [ -z "$email" ] && email="未登录"
    mark="○"; [ -f "$d/.credentials.json" ] && mark="●"
    rows+=("$mark $n  〔$email〕")
    names+=("$n")
  done
  rows+=("➕ 新建环境…")

  choice="$(choose_from "选环境（确定=进入操作），或新建。●=已登录" "${rows[@]}")"
  [ -z "$choice" ] && exit 0
  if [ "$choice" = "➕ 新建环境…" ]; then new_env_flow; continue; fi

  # 把选中行映射回环境名
  sel=""; i=1
  for r in "${rows[@]}"; do
    if [ "$r" = "$choice" ]; then sel="${names[$i]}"; break; fi
    ((i++))
  done
  [ -z "$sel" ] && continue

  act="$(ask_buttons "环境【$sel】" "打开窗口" "设默认项目" "删除")"
  case "$act" in
    "打开窗口") open_env "$sel" ;;
    "设默认项目")
      p="$(choose_folder "选环境【$sel】默认打开的项目目录")"
      [ -n "$p" ] && printf '{"defaultProject":"%s"}\n' "$p" > "$ENVS/$sel/env-meta.json" ;;
    "删除")
      c="$(ask_buttons "确定删除环境【$sel】？含登录态，不影响其它环境。" "取消" "删除")"
      [ "$c" = "删除" ] && rm -rf "$ENVS/$sel" ;;
    *) : ;;
  esac
done
