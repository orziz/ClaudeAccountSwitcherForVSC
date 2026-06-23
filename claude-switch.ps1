#requires -version 5
<#
  Claude 账号切换器  (claude.ai 邮箱登录 / Claude Code 凭据)
  原理：切换账号 = 整体替换两处身份信息
    1. ~/.claude/.credentials.json   —— OAuth 令牌（登录态核心）
    2. ~/.claude.json 里的 oauthAccount 块 —— 账号身份
  其余 .claude.json 内容（项目、MCP、缓存）账号无关，保持不动。
  每个账号存一份本地快照(profile)，切换时覆盖回去，无需退出登录、无需重输邮箱。
#>
param([switch]$SelfTest)

# ---------------- 路径 ----------------
$script:HomeDir     = $env:USERPROFILE
$script:ClaudeDir   = Join-Path $script:HomeDir '.claude'
$script:CredPath    = Join-Path $script:ClaudeDir '.credentials.json'
$script:ClaudeJson  = Join-Path $script:HomeDir '.claude.json'
$script:ToolDir     = $PSScriptRoot
$script:ProfilesDir = Join-Path $script:ToolDir 'profiles'
$script:BackupsDir  = Join-Path $script:ToolDir 'backups'

# ---------------- 文件读写（UTF-8 无 BOM，保持 Claude 原格式） ----------------
function Read-TextFile($p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-TextFile($p, $t) {
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($p, $t, $enc)
}

# ---------------- oauthAccount 文本定位（字符串感知的花括号匹配） ----------------
function Find-MatchingBrace($s, $open) {
    # $s[$open] 必须是 '{'，返回与之匹配的 '}' 下标；找不到返回 -1
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $open; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($inStr) {
            if ($esc) { $esc = $false }
            elseif ($c -eq '\') { $esc = $true }
            elseif ($c -eq '"') { $inStr = $false }
        }
        else {
            if ($c -eq '"') { $inStr = $true }
            elseif ($c -eq '{') { $depth++ }
            elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $i } }
        }
    }
    return -1
}

function Get-OAuthSpan($content) {
    # 返回 @{Start=;End=}（value 对象 '{...}' 的首尾下标），找不到返回 $null
    $k = $content.IndexOf('"oauthAccount"')
    if ($k -lt 0) { return $null }
    $colon = $content.IndexOf(':', $k + 14)
    if ($colon -lt 0) { return $null }
    $i = $colon + 1
    while ($i -lt $content.Length -and $content[$i] -ne '{') { $i++ }
    if ($i -ge $content.Length) { return $null }
    $close = Find-MatchingBrace $content $i
    if ($close -lt 0) { return $null }
    return @{ Start = $i; End = $close }
}

function Get-CurrentOAuthText {
    if (-not (Test-Path $script:ClaudeJson)) { return $null }
    $c = Read-TextFile $script:ClaudeJson
    $span = Get-OAuthSpan $c
    if (-not $span) { return $null }
    return $c.Substring($span.Start, $span.End - $span.Start + 1)
}

function Set-OAuthInClaudeJson($newValueText) {
    $c = Read-TextFile $script:ClaudeJson
    $span = Get-OAuthSpan $c
    if ($span) {
        $new = $c.Substring(0, $span.Start) + $newValueText + $c.Substring($span.End + 1)
    }
    else {
        # 当前未登录 / 无 oauthAccount：插入到首个 '{' 之后
        $fb = $c.IndexOf('{')
        if ($fb -lt 0) { throw '.claude.json 格式异常，无法写入。' }
        $new = $c.Substring(0, $fb + 1) + "`n  `"oauthAccount`": $newValueText," + $c.Substring($fb + 1)
    }
    Write-TextFile $script:ClaudeJson $new
}

function Get-EmailFromOAuthText($t) {
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json).emailAddress } catch { return $null }
}

# ---------------- 账号档加密（AES-256-CBC / PBKDF2-SHA256，与 openssl Salted__ 格式一致，跨平台可互解）----------------
# 需 .NET 4.7.2+（Win10 自带）。密文布局： "Salted__"(8) + salt(8) + AES-CBC密文。
function Protect-Cred([string]$plain, [string]$pass) {
    $salt = New-Object byte[] 8
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)
    $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pass, $salt, 200000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
    $keyiv = $kdf.GetBytes(48)
    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.BlockSize = 128
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = [byte[]]($keyiv[0..31]); $aes.IV = [byte[]]($keyiv[32..47])
    $pt = [System.Text.Encoding]::UTF8.GetBytes($plain)
    $ct = $aes.CreateEncryptor().TransformFinalBlock($pt, 0, $pt.Length)
    $aes.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $magic = [System.Text.Encoding]::ASCII.GetBytes('Salted__')
    $ms.Write($magic, 0, 8); $ms.Write($salt, 0, 8); $ms.Write($ct, 0, $ct.Length)
    return $ms.ToArray()
}
function Unprotect-Cred([byte[]]$blob, [string]$pass) {
    try {
        if ($blob.Length -lt 16) { return $null }
        if ([System.Text.Encoding]::ASCII.GetString($blob, 0, 8) -ne 'Salted__') { return $null }
        $salt = [byte[]]($blob[8..15])
        $ct = [byte[]]($blob[16..($blob.Length - 1)])
        $kdf = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($pass, $salt, 200000, [System.Security.Cryptography.HashAlgorithmName]::SHA256)
        $keyiv = $kdf.GetBytes(48)
        $aes = [System.Security.Cryptography.Aes]::Create()
        $aes.KeySize = 256; $aes.BlockSize = 128
        $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
        $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
        $aes.Key = [byte[]]($keyiv[0..31]); $aes.IV = [byte[]]($keyiv[32..47])
        $pt = $aes.CreateDecryptor().TransformFinalBlock($ct, 0, $ct.Length)
        $aes.Dispose()
        return [System.Text.Encoding]::UTF8.GetString($pt)
    } catch { return $null }
}
function Test-CredText([string]$t) {  # 错口令可能解出垃圾（padding 偶然合法），故必须查内容
    return ($t -and $t.StartsWith('{') -and $t.Contains('claudeAiOauth') -and $t.Contains('accessToken'))
}

# ---------------- 账号档(profile) ----------------
function Get-Profiles {
    if (-not (Test-Path $script:ProfilesDir)) { return @() }
    Get-ChildItem $script:ProfilesDir -Directory | ForEach-Object {
        $email = '?'; $saved = ''
        $meta = Join-Path $_.FullName 'meta.json'
        if (Test-Path $meta) {
            try { $m = Get-Content $meta -Raw | ConvertFrom-Json; $email = $m.email; $saved = $m.savedAt } catch {}
        }
        $encd = Test-Path (Join-Path $_.FullName 'credentials.json.enc')
        [pscustomobject]@{ Name = $_.Name; Email = $email; SavedAt = $saved; Dir = $_.FullName; Encrypted = $encd }
    }
}

function Save-ProfileSnapshot($name, $dir, $pass) {
    # 把“当前登录态”写进指定 profile 目录；给了 $pass 则加密令牌(不留明文)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not (Test-Path $script:CredPath)) { throw '找不到 .credentials.json，当前可能未登录。' }
    $oauth = Get-CurrentOAuthText
    if (-not $oauth) { throw '当前 .claude.json 中找不到登录信息（oauthAccount），可能未登录。' }
    $credFile = Join-Path $dir 'credentials.json'
    $encFile = Join-Path $dir 'credentials.json.enc'
    if ($pass) {
        $blob = Protect-Cred (Read-TextFile $script:CredPath) $pass
        [System.IO.File]::WriteAllBytes($encFile, $blob)
        Remove-Item $credFile -ErrorAction SilentlyContinue
    }
    else {
        Copy-Item $script:CredPath $credFile -Force
        Remove-Item $encFile -ErrorAction SilentlyContinue
    }
    Write-TextFile (Join-Path $dir 'oauthAccount.json') $oauth
    $email = Get-EmailFromOAuthText $oauth
    @{ email = $email; savedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); encrypted = [bool]$pass } |
        ConvertTo-Json | Set-Content (Join-Path $dir 'meta.json') -Encoding UTF8
    return $email
}

function Save-Profile($name, $pass) {
    return (Save-ProfileSnapshot $name (Join-Path $script:ProfilesDir $name) $pass)
}

function Backup-Current {
    $ts = (Get-Date).ToString('yyyyMMdd-HHmmss')
    $dir = Join-Path $script:BackupsDir $ts
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (Test-Path $script:CredPath) { Copy-Item $script:CredPath (Join-Path $dir '.credentials.json') -Force }
    if (Test-Path $script:ClaudeJson) { Copy-Item $script:ClaudeJson (Join-Path $dir '.claude.json') -Force }
    Get-ChildItem $script:BackupsDir -Directory | Sort-Object Name -Descending |
        Select-Object -Skip 10 | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    return $dir
}

function Switch-To($name, $pass) {
    $target = Join-Path $script:ProfilesDir $name
    $tCred = Join-Path $target 'credentials.json'
    $tCredEnc = Join-Path $target 'credentials.json.enc'
    $tOauth = Join-Path $target 'oauthAccount.json'
    if (-not (Test-Path $tOauth)) { throw "账号档 '$name' 不完整。" }

    # 取目标令牌文本（加密档需口令；错口令解出的垃圾用 Test-CredText 拦下）
    $credText = $null
    if (Test-Path $tCredEnc) {
        if (-not $pass) { throw '账号档已加密，需要口令。' }
        $credText = Unprotect-Cred ([System.IO.File]::ReadAllBytes($tCredEnc)) $pass
        if (-not (Test-CredText $credText)) { throw '口令错误或解密失败。' }
    }
    elseif (Test-Path $tCred) { $credText = Read-TextFile $tCred }
    else { throw "账号档 '$name' 不完整。" }

    # 切走前把“当前账号”的最新令牌回存到它自己的档（refreshToken 会轮换）；加密档跳过以免要口令
    $curOauth = Get-CurrentOAuthText
    if ($curOauth) {
        $curEmail = Get-EmailFromOAuthText $curOauth
        $match = Get-Profiles | Where-Object { $_.Email -eq $curEmail } | Select-Object -First 1
        if ($match -and $match.Name -ne $name -and -not $match.Encrypted) {
            try { Save-ProfileSnapshot $match.Name $match.Dir | Out-Null } catch {}
        }
    }

    Backup-Current | Out-Null
    Write-TextFile $script:CredPath $credText
    Set-OAuthInClaudeJson (Read-TextFile $tOauth)
}

# ======================= 自检（无需 GUI） =======================
if ($SelfTest) {
    $tmp = Join-Path $env:TEMP ('cs-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force $tmp | Out-Null
    $script:HomeDir = $tmp
    $script:ClaudeDir = Join-Path $tmp '.claude'
    New-Item -ItemType Directory -Force $script:ClaudeDir | Out-Null
    $script:CredPath = Join-Path $script:ClaudeDir '.credentials.json'
    $script:ClaudeJson = Join-Path $tmp '.claude.json'
    $script:ToolDir = Join-Path $tmp 'account-switch'
    $script:ProfilesDir = Join-Path $script:ToolDir 'profiles'
    $script:BackupsDir = Join-Path $script:ToolDir 'backups'

    $sampleJson = @'
{
  "userID": "keepme",
  "projects": { "a": { "nested": { "deep": "x" } } },
  "oauthAccount": {
    "accountUuid": "uuid-A",
    "emailAddress": "a@example.com",
    "orgRaw": "brace } and { here",
    "organizationName": "Org A"
  },
  "machineID": "stable"
}
'@
    Write-TextFile $script:ClaudeJson $sampleJson
    Write-TextFile $script:CredPath '{"claudeAiOauth":{"accessToken":"TOKEN_A"}}'
    $eA = Save-Profile 'A'

    $sampleB = $sampleJson.Replace('uuid-A', 'uuid-B').Replace('a@example.com', 'b@example.com').Replace('Org A', 'Org B')
    Write-TextFile $script:ClaudeJson $sampleB
    Write-TextFile $script:CredPath '{"claudeAiOauth":{"accessToken":"TOKEN_B"}}'
    $eB = Save-Profile 'B'

    Switch-To 'A'
    $parsed = (Read-TextFile $script:ClaudeJson) | ConvertFrom-Json
    $cred = Read-TextFile $script:CredPath

    # 加密账号档往返：存为加密档 C → 验证无明文、正确口令可解、错口令被拦、切换生效
    Write-TextFile $script:CredPath '{"claudeAiOauth":{"accessToken":"TOKEN_ENC"}}'
    $eC = Save-Profile 'C' 'pw-correct'
    $cDir = Join-Path $script:ProfilesDir 'C'
    $encExists = Test-Path (Join-Path $cDir 'credentials.json.enc')
    $plainGone = -not (Test-Path (Join-Path $cDir 'credentials.json'))
    $blobC = [System.IO.File]::ReadAllBytes((Join-Path $cDir 'credentials.json.enc'))
    $decOK = Unprotect-Cred $blobC 'pw-correct'
    $decBad = Unprotect-Cred $blobC 'pw-wrong'
    $encOK = ($encExists -and $plainGone -and (Test-CredText $decOK) -and ($decOK -match 'TOKEN_ENC') -and (-not (Test-CredText $decBad)))
    Switch-To 'C' 'pw-correct'
    $encSwitchOK = ((Read-TextFile $script:CredPath) -match 'TOKEN_ENC')

    $ok = ($eA -eq 'a@example.com') -and ($eB -eq 'b@example.com') -and
          ($parsed.oauthAccount.emailAddress -eq 'a@example.com') -and
          ($parsed.oauthAccount.orgRaw -eq 'brace } and { here') -and
          ($parsed.userID -eq 'keepme') -and ($parsed.machineID -eq 'stable') -and
          ($parsed.projects.a.nested.deep -eq 'x') -and ($cred -match 'TOKEN_A') -and
          $encOK -and $encSwitchOK
    if ($ok) { Write-Host 'SELFTEST PASS' }
    else {
        Write-Host "SELFTEST FAIL email=$($parsed.oauthAccount.emailAddress) orgRaw=$($parsed.oauthAccount.orgRaw) userID=$($parsed.userID) machineID=$($parsed.machineID) deep=$($parsed.projects.a.nested.deep) credA=$($cred -match 'TOKEN_A') encOK=$encOK encSwitch=$encSwitchOK"
    }
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    return
}

# ======================= GUI =======================
New-Item -ItemType Directory -Force -Path $script:ProfilesDir | Out-Null
New-Item -ItemType Directory -Force -Path $script:BackupsDir | Out-Null

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

function Show-InputBox($prompt, $title, $default) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    return [Microsoft.VisualBasic.Interaction]::InputBox($prompt, $title, $default)
}

function Show-PasswordBox($prompt, $title) {  # 掩码输入框；取消返回 $null
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title; $f.Size = New-Object System.Drawing.Size(380, 168)
    $f.StartPosition = 'CenterScreen'; $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $lb = New-Object System.Windows.Forms.Label
    $lb.Location = New-Object System.Drawing.Point(14, 14); $lb.Size = New-Object System.Drawing.Size(345, 40); $lb.Text = $prompt
    $f.Controls.Add($lb)
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Location = New-Object System.Drawing.Point(14, 60); $tb.Size = New-Object System.Drawing.Size(345, 26)
    $tb.UseSystemPasswordChar = $true; $f.Controls.Add($tb)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Location = New-Object System.Drawing.Point(190, 96); $ok.Size = New-Object System.Drawing.Size(80, 30); $ok.Text = '确定'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK; $f.Controls.Add($ok); $f.AcceptButton = $ok
    $cc = New-Object System.Windows.Forms.Button
    $cc.Location = New-Object System.Drawing.Point(279, 96); $cc.Size = New-Object System.Drawing.Size(80, 30); $cc.Text = '取消'
    $cc.DialogResult = [System.Windows.Forms.DialogResult]::Cancel; $f.Controls.Add($cc); $f.CancelButton = $cc
    if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $tb.Text } else { return $null }
}

function Sanitize-Name($n) { return (($n -replace '[\\/:*?"<>|]', '_').Trim()) }

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude 账号切换'
$form.Size = New-Object System.Drawing.Size(440, 470)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$lblCurrent = New-Object System.Windows.Forms.Label
$lblCurrent.Location = New-Object System.Drawing.Point(14, 12)
$lblCurrent.Size = New-Object System.Drawing.Size(400, 24)
$lblCurrent.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($lblCurrent)

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Location = New-Object System.Drawing.Point(14, 40)
$lblHint.Size = New-Object System.Drawing.Size(400, 18)
$lblHint.ForeColor = [System.Drawing.Color]::Gray
$lblHint.Text = '● 当前账号 · [密] 已加密 · 选中后点“切换到选中账号”'
$form.Controls.Add($lblHint)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Location = New-Object System.Drawing.Point(14, 64)
$listBox.Size = New-Object System.Drawing.Size(400, 250)
$listBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$form.Controls.Add($listBox)

$btnSwitch = New-Object System.Windows.Forms.Button
$btnSwitch.Location = New-Object System.Drawing.Point(14, 326)
$btnSwitch.Size = New-Object System.Drawing.Size(195, 40)
$btnSwitch.Text = '切换到选中账号'
$btnSwitch.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnSwitch)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Location = New-Object System.Drawing.Point(219, 326)
$btnSave.Size = New-Object System.Drawing.Size(195, 40)
$btnSave.Text = '保存当前为新账号'
$form.Controls.Add($btnSave)

$btnDelete = New-Object System.Windows.Forms.Button
$btnDelete.Location = New-Object System.Drawing.Point(14, 374)
$btnDelete.Size = New-Object System.Drawing.Size(195, 32)
$btnDelete.Text = '删除选中账号档'
$form.Controls.Add($btnDelete)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Location = New-Object System.Drawing.Point(219, 374)
$btnRefresh.Size = New-Object System.Drawing.Size(195, 32)
$btnRefresh.Text = '刷新'
$form.Controls.Add($btnRefresh)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = New-Object System.Drawing.Point(14, 414)
$lblStatus.Size = New-Object System.Drawing.Size(400, 20)
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblStatus)

$script:ProfileNames = @()

function Refresh-UI {
    $cur = Get-EmailFromOAuthText (Get-CurrentOAuthText)
    if ($cur) { $lblCurrent.Text = "当前账号：$cur" }
    else { $lblCurrent.Text = '当前账号：（未登录或无法识别）' }
    $listBox.Items.Clear()
    $script:ProfileNames = @()
    foreach ($p in (Get-Profiles)) {
        $mark = if ($p.Email -eq $cur) { '●' } else { ' ' }
        $enc = if ($p.Encrypted) { '[密]' } else { '   ' }
        [void]$listBox.Items.Add(('{0}{1} {2,-10} {3,-26} {4}' -f $mark, $enc, $p.Name, $p.Email, $p.SavedAt))
        $script:ProfileNames += $p.Name
    }
    $lblStatus.Text = "共 $($script:ProfileNames.Count) 个账号档"
}

$btnSwitch.Add_Click({
    if ($listBox.SelectedIndex -lt 0) {
        [void][System.Windows.Forms.MessageBox]::Show('请先在列表里选一个账号。', '提示'); return
    }
    $name = $script:ProfileNames[$listBox.SelectedIndex]
    $running = @(Get-Process -Name claude -ErrorAction SilentlyContinue)
    $warn = if ($running.Count -gt 0) { "`n`n注意：检测到正在运行的 Claude 进程，切换可能被它覆盖，建议先关闭所有 Claude Code 会话。" } else { '' }
    $r = [System.Windows.Forms.MessageBox]::Show("切换到账号档 [$name]？$warn", '确认切换',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    try {
        $pass = $null
        $prof = Get-Profiles | Where-Object { $_.Name -eq $name } | Select-Object -First 1
        if ($prof -and $prof.Encrypted) {
            $pass = Show-PasswordBox "账号档 [$name] 已加密，输入口令解锁：" '解锁'
            if ([string]::IsNullOrEmpty($pass)) { return }
        }
        Switch-To $name $pass
        Refresh-UI
        [void][System.Windows.Forms.MessageBox]::Show("已切换到 [$name]。`n请重新打开 Claude Code 会话以生效。", '完成')
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show("切换失败：$($_.Exception.Message)", '错误') }
})

$btnSave.Add_Click({
    $cur = Get-EmailFromOAuthText (Get-CurrentOAuthText)
    $def = if ($cur) { ($cur -split '@')[0] } else { '账号1' }
    $name = Sanitize-Name (Show-InputBox '给当前登录的账号起个名字（如 工作 / 私人）：' '保存账号档' $def)
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    $pass = $null
    $re = [System.Windows.Forms.MessageBox]::Show("是否加密保存此账号档？`n（加密=令牌不留明文，每次使用需输口令）", '加密',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($re -eq [System.Windows.Forms.DialogResult]::Yes) {
        $pass = Show-PasswordBox '设置加密口令（务必记住，丢失则无法恢复）：' '加密口令'
        if ([string]::IsNullOrEmpty($pass)) { return }
        $pass2 = Show-PasswordBox '再次输入口令确认：' '加密口令'
        if ($pass -ne $pass2) { [void][System.Windows.Forms.MessageBox]::Show('两次口令不一致，已取消。', '提示'); return }
    }
    try {
        $email = Save-Profile $name $pass
        Refresh-UI
        [void][System.Windows.Forms.MessageBox]::Show("已保存：[$name]  $email", '完成')
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show("保存失败：$($_.Exception.Message)", '错误') }
})

$btnDelete.Add_Click({
    if ($listBox.SelectedIndex -lt 0) { return }
    $name = $script:ProfileNames[$listBox.SelectedIndex]
    $r = [System.Windows.Forms.MessageBox]::Show("删除账号档 [$name]？`n（只删本地快照，不影响实际登录）", '确认删除',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Remove-Item -Recurse -Force (Join-Path $script:ProfilesDir $name) -ErrorAction SilentlyContinue
        Refresh-UI
    }
})

$btnRefresh.Add_Click({ Refresh-UI })

# 首次使用：若没有任何账号档，且当前已登录，引导存为第一个
if ((Get-Profiles).Count -eq 0) {
    $cur = Get-EmailFromOAuthText (Get-CurrentOAuthText)
    if ($cur) {
        $r = [System.Windows.Forms.MessageBox]::Show("检测到当前登录：$cur`n是否把它存为第一个账号档？", '首次使用',
            [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
        if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
            $name = Sanitize-Name (Show-InputBox '账号档名字：' '保存账号档' (($cur -split '@')[0]))
            if (-not [string]::IsNullOrWhiteSpace($name)) { try { Save-Profile $name | Out-Null } catch {} }
        }
    }
}

Refresh-UI
[void]$form.ShowDialog()
