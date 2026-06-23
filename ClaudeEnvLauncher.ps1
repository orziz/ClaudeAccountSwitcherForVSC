#requires -version 5
<#
  Claude 多账号 · 环境启动台
  ---------------------------------------------------------------
  每个「环境」= 独立 CLAUDE_CONFIG_DIR（自带 .claude.json/.credentials.json，一套独立登录态）
            + 独立 VSCode --user-data-dir（强制独立进程，环境变量才隔离得开）
  选中环境点「打开窗口」→ 启动一个绑定该账号的独立 VSCode 实例。
  多个环境可同时开着，各用各的号、各管各的额度，互不覆盖。

  账号绑定两种方式：
    1) 现场登录   —— 新环境第一次开窗时在里面 /login 一次，永久记住
    2) 免登录灌入 —— 复用「当前登录的号」或「已存账号档」的凭据，直接拷进新环境
#>
param([switch]$SelfTest)

# ---------------- 路径 ----------------
$script:Root           = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Definition }
$script:EnvsDir        = Join-Path $script:Root 'envs'
$script:ProfilesDir    = Join-Path $script:Root 'profiles'      # 旧切号工具存的账号档（灌入用）
$script:HomeCred       = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$script:HomeClaudeJson = Join-Path $env:USERPROFILE '.claude.json'

# ---------------- 文件读写（UTF-8 无 BOM，保持 Claude 原格式） ----------------
function Read-TextFile($p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-TextFile($p, $t) {
    [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
}

# ---------------- 权限收紧（NTFS ACL 收到「仅当前用户」，等价 macOS 的 umask 077；失败不致命）----------------
function Lock-Private($path) {
    # 用全新的「只含 DACL」安全描述符覆盖：仅写 DACL（只需 WRITE_DAC，属主自带），
    # 避免 Set-Acl 回写 SACL/属主导致的 SeSecurityPrivilege 报错。
    try {
        if (-not (Test-Path -LiteralPath $path)) { return }
        $item = Get-Item -LiteralPath $path -Force
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        if ($item.PSIsContainer) {
            $sec = New-Object System.Security.AccessControl.DirectorySecurity
            $inh = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
        } else {
            $sec = New-Object System.Security.AccessControl.FileSecurity
            $inh = [System.Security.AccessControl.InheritanceFlags]::None
        }
        $sec.SetAccessRuleProtection($true, $false)   # 断继承 + 不保留继承来的规则
        $sec.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', $inh, 'None', 'Allow')))
        $item.SetAccessControl($sec)
    } catch {}
}
function Lock-PrivateData {
    # 启动时一次性收紧数据目录及其中已有的敏感文件（不动 vscode-userdata 等非敏感内容）
    $sensitive = '.credentials.json', '.claude.json', 'credentials.json', 'credentials.json.enc', 'oauthAccount.json'
    foreach ($root in @($script:EnvsDir, $script:ProfilesDir)) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Lock-Private $root
        Get-ChildItem -LiteralPath $root -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object { $sensitive -contains $_.Name } | ForEach-Object { Lock-Private $_.FullName }
    }
}

# ---------------- oauthAccount 文本定位（字符串感知的花括号匹配） ----------------
function Find-MatchingBrace($s, $open) {
    $depth = 0; $inStr = $false; $esc = $false
    for ($i = $open; $i -lt $s.Length; $i++) {
        $c = $s[$i]
        if ($inStr) {
            if ($esc) { $esc = $false } elseif ($c -eq '\') { $esc = $true } elseif ($c -eq '"') { $inStr = $false }
        }
        else {
            if ($c -eq '"') { $inStr = $true } elseif ($c -eq '{') { $depth++ } elseif ($c -eq '}') { $depth--; if ($depth -eq 0) { return $i } }
        }
    }
    return -1
}
function Get-OAuthText($claudeJsonPath) {
    if (-not (Test-Path $claudeJsonPath)) { return $null }
    $c = Read-TextFile $claudeJsonPath
    $k = $c.IndexOf('"oauthAccount"'); if ($k -lt 0) { return $null }
    $colon = $c.IndexOf(':', $k + 14); if ($colon -lt 0) { return $null }
    $i = $colon + 1; while ($i -lt $c.Length -and $c[$i] -ne '{') { $i++ }
    if ($i -ge $c.Length) { return $null }
    $close = Find-MatchingBrace $c $i; if ($close -lt 0) { return $null }
    return $c.Substring($i, $close - $i + 1)
}
function Get-EmailFromOAuthText($t) {
    if (-not $t) { return $null }
    try { return ($t | ConvertFrom-Json).emailAddress } catch { return $null }
}
function New-SeedClaudeJson($oauthText) { return "{`n  `"oauthAccount`": $oauthText`n}" }

# ---------------- 账号档加密（AES-256-CBC / PBKDF2-SHA256，与 openssl Salted__ / mac 端一致）----------------
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
    $ms.Write([System.Text.Encoding]::ASCII.GetBytes('Salted__'), 0, 8); $ms.Write($salt, 0, 8); $ms.Write($ct, 0, $ct.Length)
    return $ms.ToArray()
}
function Unprotect-Cred([byte[]]$blob, [string]$pass) {
    try {
        if ($blob.Length -lt 16) { return $null }
        if ([System.Text.Encoding]::ASCII.GetString($blob, 0, 8) -ne 'Salted__') { return $null }
        $salt = [byte[]]($blob[8..15]); $ct = [byte[]]($blob[16..($blob.Length - 1)])
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
function Test-CredText([string]$t) {
    return ($t -and $t.StartsWith('{') -and $t.Contains('claudeAiOauth') -and $t.Contains('accessToken'))
}

# ---------------- 环境 / 账号档 ----------------
function Get-EnvEmail($envDir) {
    $cj = Join-Path $envDir '.claude.json'
    if (-not (Test-Path $cj)) { return $null }
    try { return (Read-TextFile $cj | ConvertFrom-Json).oauthAccount.emailAddress } catch { return $null }
}
function Get-Envs {
    if (-not (Test-Path $script:EnvsDir)) { return @() }
    Get-ChildItem $script:EnvsDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $proj = ''
        $meta = Join-Path $_.FullName 'env-meta.json'
        if (Test-Path $meta) { try { $proj = (Get-Content $meta -Raw | ConvertFrom-Json).defaultProject } catch {} }
        [pscustomobject]@{
            Name           = $_.Name
            Dir            = $_.FullName
            Email          = Get-EnvEmail $_.FullName
            LoggedIn       = Test-Path (Join-Path $_.FullName '.credentials.json')
            DefaultProject = $proj
        }
    }
}
function Get-Profiles {
    if (-not (Test-Path $script:ProfilesDir)) { return @() }
    Get-ChildItem $script:ProfilesDir -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $email = '?'
        $meta = Join-Path $_.FullName 'meta.json'
        if (Test-Path $meta) { try { $email = (Get-Content $meta -Raw | ConvertFrom-Json).email } catch {} }
        $encd = Test-Path (Join-Path $_.FullName 'credentials.json.enc')
        [pscustomobject]@{ Name = $_.Name; Email = $email; Dir = $_.FullName; Encrypted = $encd }
    }
}

function Seed-Env($envDir, $credSrcPath, $oauthText) {
    if (-not (Test-Path $credSrcPath)) { throw "源凭据不存在：$credSrcPath" }
    if (-not $oauthText) { throw '源账号缺少身份信息（oauthAccount）。' }
    Copy-Item $credSrcPath (Join-Path $envDir '.credentials.json') -Force
    Write-TextFile (Join-Path $envDir '.claude.json') (New-SeedClaudeJson $oauthText)
}

function Seed-VSCodeSettings($uddDir) {
    # 把用户真实 VSCode 的 settings/keybindings/snippets 拷进环境，使新窗口不是白板。
    # （扩展本就共享自 ~/.vscode/extensions，无需重装；这里只补设置。）
    try {
        $srcUser = Join-Path $env:APPDATA 'Code\User'
        if (-not (Test-Path $srcUser)) { return }
        $dstUser = Join-Path $uddDir 'User'
        New-Item -ItemType Directory -Force $dstUser | Out-Null
        foreach ($item in 'settings.json', 'keybindings.json') {
            $s = Join-Path $srcUser $item
            if (Test-Path $s) { Copy-Item $s (Join-Path $dstUser $item) -Force }
        }
        $snip = Join-Path $srcUser 'snippets'
        if (Test-Path $snip) { Copy-Item $snip $dstUser -Recurse -Force }
    }
    catch {}
}

function New-Env($name, $defaultProject, $bindMode, $sourceDir, $pass) {
    $envDir = Join-Path $script:EnvsDir $name
    if (Test-Path $envDir) { throw "环境【$name】已存在。" }
    New-Item -ItemType Directory -Force (Join-Path $envDir 'vscode-userdata') | Out-Null
    Seed-VSCodeSettings (Join-Path $envDir 'vscode-userdata')   # 带上你常用的 VSCode 设置，免得是张白纸
    try {
        @{ defaultProject = $defaultProject; createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
            ConvertTo-Json | Set-Content (Join-Path $envDir 'env-meta.json') -Encoding UTF8
        switch ($bindMode) {
            'current' { Seed-Env $envDir $script:HomeCred (Get-OAuthText $script:HomeClaudeJson) }
            'profile' {
                $encf = Join-Path $sourceDir 'credentials.json.enc'
                $oauthText = Read-TextFile (Join-Path $sourceDir 'oauthAccount.json')
                if (Test-Path $encf) {                       # 加密账号档：解密后写入
                    if (-not $oauthText) { throw '源账号缺少身份信息（oauthAccount）。' }
                    $credText = Unprotect-Cred ([System.IO.File]::ReadAllBytes($encf)) $pass
                    if (-not (Test-CredText $credText)) { throw '口令错误或解密失败。' }
                    Write-TextFile (Join-Path $envDir '.credentials.json') $credText
                    Write-TextFile (Join-Path $envDir '.claude.json') (New-SeedClaudeJson $oauthText)
                }
                else { Seed-Env $envDir (Join-Path $sourceDir 'credentials.json') $oauthText }
            }
            default   { } # 'login' —— 留空，开窗后自己登
        }
    }
    catch {
        Remove-Item -LiteralPath $envDir -Recurse -Force -ErrorAction SilentlyContinue  # 失败回滚，避免残留半成品挡重试
        throw
    }
    Lock-Private $envDir
    foreach ($f in '.credentials.json', '.claude.json') { Lock-Private (Join-Path $envDir $f) }
    return $envDir
}

function Find-CodeCmd {
    $c = Get-Command code -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    $cands = @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd",
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd",
        "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd",
        'C:\apps\Microsoft VS Code\bin\code.cmd'
    )
    foreach ($p in $cands) { if ($p -and (Test-Path $p)) { return $p } }
    throw '找不到 VSCode 的 code 命令，请确保已安装 VSCode。'
}
function Get-UserLocale {
    # 从 ~/.vscode/argv.json 读界面语言（含注释，用正则抠）
    $argv = Join-Path $env:USERPROFILE '.vscode\argv.json'
    if (-not (Test-Path $argv)) { return $null }
    try { if ((Get-Content $argv -Raw) -match '"locale"\s*:\s*"([^"]+)"') { return $Matches[1] } } catch {}
    return $null
}
function Open-EnvWindow($name, $defaultProject) {
    $cfg = Join-Path $script:EnvsDir $name
    $udd = Join-Path $cfg 'vscode-userdata'
    New-Item -ItemType Directory -Force $udd | Out-Null
    $env:CLAUDE_CONFIG_DIR = $cfg
    $codeArgs = @('--user-data-dir', $udd, '--new-window')
    $loc = Get-UserLocale
    if ($loc) { $codeArgs += @('--locale', $loc) }   # 让独立窗口也是你的界面语言
    if ($defaultProject -and (Test-Path $defaultProject)) { $codeArgs += $defaultProject }
    & (Find-CodeCmd) @codeArgs
}

# ======================= 自检（无需 GUI） =======================
if ($SelfTest) {
    $tmp = Join-Path $env:TEMP ('envtest-' + [guid]::NewGuid().ToString('N'))
    $script:EnvsDir = Join-Path $tmp 'envs'
    $script:ProfilesDir = Join-Path $tmp 'profiles'
    New-Item -ItemType Directory -Force $script:EnvsDir | Out-Null

    # 造一个假「当前账号」来源
    $fakeHomeCred = Join-Path $tmp 'home.credentials.json'
    Write-TextFile $fakeHomeCred '{"claudeAiOauth":{"accessToken":"TOK"}}'
    $script:HomeCred = $fakeHomeCred
    $fakeClaudeJson = Join-Path $tmp 'home.claude.json'
    Write-TextFile $fakeClaudeJson '{"userID":"u","oauthAccount":{"emailAddress":"work@x.com","orgRaw":"a } b { c","organizationName":"W"},"machineID":"m"}'
    $script:HomeClaudeJson = $fakeClaudeJson

    # 1) login 模式：建空环境
    New-Env 'e-login' '' 'login' $null | Out-Null
    $ok1 = (Test-Path (Join-Path $script:EnvsDir 'e-login\vscode-userdata')) -and
           -not (Test-Path (Join-Path $script:EnvsDir 'e-login\.credentials.json'))

    # 2) current 模式：从假「当前账号」灌入
    New-Env 'e-current' 'E:\proj\a' 'current' $null | Out-Null
    $cjPath = Join-Path $script:EnvsDir 'e-current\.claude.json'
    $parsed = Read-TextFile $cjPath | ConvertFrom-Json
    $ok2 = (Test-Path (Join-Path $script:EnvsDir 'e-current\.credentials.json')) -and
           ($parsed.oauthAccount.emailAddress -eq 'work@x.com') -and
           ($parsed.oauthAccount.orgRaw -eq 'a } b { c')   # 花括号在字符串里也被正确截取

    # 3) profile 模式
    $pdir = Join-Path $script:ProfilesDir 'p1'
    New-Item -ItemType Directory -Force $pdir | Out-Null
    Write-TextFile (Join-Path $pdir 'credentials.json') '{"claudeAiOauth":{"accessToken":"TOK2"}}'
    Write-TextFile (Join-Path $pdir 'oauthAccount.json') '{"emailAddress":"personal@y.com","organizationName":"P"}'
    '{"email":"personal@y.com"}' | Set-Content (Join-Path $pdir 'meta.json') -Encoding UTF8
    New-Env 'e-profile' '' 'profile' $pdir | Out-Null
    $p3 = Read-TextFile (Join-Path $script:EnvsDir 'e-profile\.claude.json') | ConvertFrom-Json
    $ok3 = ($p3.oauthAccount.emailAddress -eq 'personal@y.com') -and
           (Test-Path (Join-Path $script:EnvsDir 'e-profile\.credentials.json'))

    # 3b) profile 模式 · 加密账号档（解密灌入 + 错口令应失败 + 不留明文）
    $pdir2 = Join-Path $script:ProfilesDir 'p2'
    New-Item -ItemType Directory -Force $pdir2 | Out-Null
    [System.IO.File]::WriteAllBytes((Join-Path $pdir2 'credentials.json.enc'), (Protect-Cred '{"claudeAiOauth":{"accessToken":"TOKENC"}}' 'pw123'))
    Write-TextFile (Join-Path $pdir2 'oauthAccount.json') '{"emailAddress":"enc@z.com","organizationName":"Z"}'
    '{"email":"enc@z.com"}' | Set-Content (Join-Path $pdir2 'meta.json') -Encoding UTF8
    New-Env 'e-profenc' '' 'profile' $pdir2 'pw123' | Out-Null
    $peCred = Read-TextFile (Join-Path $script:EnvsDir 'e-profenc\.credentials.json')
    $peClaude = Read-TextFile (Join-Path $script:EnvsDir 'e-profenc\.claude.json') | ConvertFrom-Json
    $wrongFailed = $false
    try { New-Env 'e-wrongpw' '' 'profile' $pdir2 'BADpw' | Out-Null } catch { $wrongFailed = $true }
    $ok5 = ($peCred -match 'TOKENC') -and ($peClaude.oauthAccount.emailAddress -eq 'enc@z.com') -and
           $wrongFailed -and (-not (Test-Path (Join-Path $pdir2 'credentials.json'))) -and
           (-not (Test-Path (Join-Path $script:EnvsDir 'e-wrongpw')))

    # 4) Get-Envs 回读
    $envs = Get-Envs
    $ok4 = ($envs.Count -eq 4) -and
           (($envs | Where-Object { $_.Name -eq 'e-current' }).Email -eq 'work@x.com') -and
           (($envs | Where-Object { $_.Name -eq 'e-current' }).DefaultProject -eq 'E:\proj\a') -and
           (-not ($envs | Where-Object { $_.Name -eq 'e-login' }).LoggedIn) -and
           (($envs | Where-Object { $_.Name -eq 'e-profile' }).LoggedIn)

    if ($ok1 -and $ok2 -and $ok3 -and $ok4 -and $ok5) { Write-Host 'SELFTEST PASS' }
    else { Write-Host "SELFTEST FAIL  ok1=$ok1 ok2=$ok2 ok3=$ok3 ok4=$ok4 ok5=$ok5" }
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    return
}

# ======================= GUI =======================
New-Item -ItemType Directory -Force $script:EnvsDir | Out-Null
Lock-PrivateData
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

function Pick-Folder($desc) {
    $d = New-Object System.Windows.Forms.FolderBrowserDialog
    $d.Description = $desc
    if ($d.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $d.SelectedPath }
    return $null
}

# 通用：多按钮选择对话框，返回点击的按钮序号(0..n-1)，取消返回 -1
function Show-ChoiceDialog($title, $message, [string[]]$choices) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title; $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $f.ClientSize = New-Object System.Drawing.Size(380, (60 + $choices.Count * 44))
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text = $message; $lbl.Location = '15,12'; $lbl.Size = '350,36'
    $f.Controls.Add($lbl)
    $script:__choiceResult = -1
    $script:__choiceForm = $f
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $b = New-Object System.Windows.Forms.Button
        $b.Text = $choices[$i]
        $b.Location = New-Object System.Drawing.Point(15, (52 + $i * 44))
        $b.Size = New-Object System.Drawing.Size(350, 36)
        # 把序号烧进处理器字符串，绕开 $this / 闭包捕获坑
        $b.Add_Click([scriptblock]::Create("`$script:__choiceResult = $i; `$script:__choiceForm.Close()"))
        $f.Controls.Add($b)
    }
    [void]$f.ShowDialog()
    return $script:__choiceResult
}

# 通用：列表单选对话框，返回选中字符串或 $null
function Show-ListPick($title, [string[]]$items) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title; $f.StartPosition = 'CenterParent'
    $f.FormBorderStyle = 'FixedDialog'; $f.MaximizeBox = $false; $f.MinimizeBox = $false
    $f.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
    $f.ClientSize = New-Object System.Drawing.Size(340, 260)
    $lb = New-Object System.Windows.Forms.ListBox
    $lb.Location = '12,12'; $lb.Size = '316,200'
    foreach ($it in $items) { [void]$lb.Items.Add($it) }
    if ($lb.Items.Count) { $lb.SelectedIndex = 0 }
    $f.Controls.Add($lb)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = '确定'; $ok.Location = '160,222'; $ok.Size = '80,28'
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.Controls.Add($ok); $f.AcceptButton = $ok
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = '取消'; $cancel.Location = '248,222'; $cancel.Size = '80,28'
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.Add($cancel); $f.CancelButton = $cancel
    if ($f.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK -and $lb.SelectedItem) { return [string]$lb.SelectedItem }
    return $null
}

# ---------------- 主窗口 ----------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude 多账号 · 环境启动台'
$form.Size = New-Object System.Drawing.Size(560, 500)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$form.FormBorderStyle = 'FixedSingle'; $form.MaximizeBox = $false

$lblHint = New-Object System.Windows.Forms.Label
$lblHint.Location = '14,10'; $lblHint.Size = '520,40'
$lblHint.Text = '每个环境 = 一个独立账号 + 一套独立 VSCode 实例。选中点「打开窗口」即启动一个绑定该账号的窗口；' +
                '多个窗口可同时各用各的号。●=已登录'
$form.Controls.Add($lblHint)

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Location = '14,54'; $listBox.Size = '520,250'
$listBox.Font = New-Object System.Drawing.Font('Consolas', 10)
$form.Controls.Add($listBox)

$btnOpen = New-Object System.Windows.Forms.Button
$btnOpen.Location = '14,314'; $btnOpen.Size = '170,44'
$btnOpen.Text = '打开窗口'
$btnOpen.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 10, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnOpen)

$btnNew = New-Object System.Windows.Forms.Button
$btnNew.Location = '194,314'; $btnNew.Size = '170,44'; $btnNew.Text = '新建环境...'
$form.Controls.Add($btnNew)

$btnProj = New-Object System.Windows.Forms.Button
$btnProj.Location = '374,314'; $btnProj.Size = '160,44'; $btnProj.Text = '设默认项目...'
$form.Controls.Add($btnProj)

$btnDel = New-Object System.Windows.Forms.Button
$btnDel.Location = '14,366'; $btnDel.Size = '170,30'; $btnDel.Text = '删除环境'
$form.Controls.Add($btnDel)

$btnRefresh = New-Object System.Windows.Forms.Button
$btnRefresh.Location = '194,366'; $btnRefresh.Size = '170,30'; $btnRefresh.Text = '刷新'
$form.Controls.Add($btnRefresh)

$btnSwitch = New-Object System.Windows.Forms.Button
$btnSwitch.Location = '374,366'; $btnSwitch.Size = '160,30'; $btnSwitch.Text = '单窗口切号(旧)…'
$btnSwitch.Add_Click({
    $old = Join-Path $script:Root 'claude-switch.ps1'
    if (-not (Test-Path $old)) { [void][System.Windows.Forms.MessageBox]::Show('旧版切号工具 claude-switch.ps1 不在本目录。'); return }
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-Sta', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $old)
})
$form.Controls.Add($btnSwitch)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Location = '14,404'; $lblStatus.Size = '520,20'
$lblStatus.ForeColor = [System.Drawing.Color]::DimGray
$form.Controls.Add($lblStatus)

$script:EnvNames = @()
function Refresh-UI {
    $listBox.Items.Clear(); $script:EnvNames = @()
    foreach ($e in (Get-Envs)) {
        $mark = if ($e.LoggedIn) { '●' } else { '○' }
        $acct = if ($e.Email) { $e.Email } elseif ($e.LoggedIn) { '(已登录)' } else { '未登录' }
        $proj = if ($e.DefaultProject) { ' → ' + (Split-Path $e.DefaultProject -Leaf) } else { '' }
        [void]$listBox.Items.Add(('{0} {1,-12} {2,-26}{3}' -f $mark, $e.Name, $acct, $proj))
        $script:EnvNames += $e.Name
    }
    $lblStatus.Text = "共 $($script:EnvNames.Count) 个环境"
}

function Selected-Env { if ($listBox.SelectedIndex -lt 0) { return $null } return $script:EnvNames[$listBox.SelectedIndex] }

$btnNew.Add_Click({
    $name = Sanitize-Name (Show-InputBox '环境名（如 工作 / 外包 / 开源 / 个人）：' '新建环境' '')
    if ([string]::IsNullOrWhiteSpace($name)) { return }
    if (Test-Path (Join-Path $script:EnvsDir $name)) { [void][System.Windows.Forms.MessageBox]::Show("环境【$name】已存在。"); return }
    $proj = Pick-Folder "选环境【$name】默认打开的项目目录（可取消=不设）"

    $curEmail = Get-EmailFromOAuthText (Get-OAuthText $script:HomeClaudeJson)
    $curTxt = if ($curEmail) { "用当前登录的号（$curEmail）" } else { '用当前登录的号（当前未登录，不可选）' }
    $idx = Show-ChoiceDialog '账号绑定' "环境【$name】绑定哪个号？" @('现场登录（开窗后自己 /login 一次）', $curTxt, '从已存账号档灌入...')

    try {
        switch ($idx) {
            0 { New-Env $name $proj 'login' $null | Out-Null }
            1 {
                if (-not $curEmail) { [void][System.Windows.Forms.MessageBox]::Show('当前默认账号未登录，改用现场登录。'); New-Env $name $proj 'login' $null | Out-Null }
                else { New-Env $name $proj 'current' $null | Out-Null }
            }
            2 {
                $profs = Get-Profiles
                if (-not $profs.Count) { [void][System.Windows.Forms.MessageBox]::Show('还没有已存账号档（可用旧的切号工具「保存当前为新账号」先存）。本次改用现场登录。'); New-Env $name $proj 'login' $null | Out-Null }
                else {
                    $pick = Show-ListPick '选要灌入的账号档' ($profs | ForEach-Object { "$($_.Name)  〔$($_.Email)〕$(if ($_.Encrypted) { '  [加密]' })" })
                    if (-not $pick) { return }
                    $pname = ($pick -split '  〔')[0]
                    $sel = $profs | Where-Object { $_.Name -eq $pname } | Select-Object -First 1
                    $ppass = $null
                    if ($sel.Encrypted) {
                        $ppass = Show-PasswordBox "账号档 [$pname] 已加密，输入口令解锁：" '解锁'
                        if ([string]::IsNullOrEmpty($ppass)) { return }
                    }
                    New-Env $name $proj 'profile' $sel.Dir $ppass | Out-Null
                }
            }
            default { return }
        }
        Refresh-UI
        [void][System.Windows.Forms.MessageBox]::Show("环境【$name】已建好。`n点「打开窗口」启动它。")
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show("新建失败：$($_.Exception.Message)") }
})

$btnOpen.Add_Click({
    $name = Selected-Env
    if (-not $name) { [void][System.Windows.Forms.MessageBox]::Show('先选一个环境。'); return }
    $proj = ''
    $meta = Join-Path $script:EnvsDir "$name\env-meta.json"
    if (Test-Path $meta) { try { $proj = (Get-Content $meta -Raw | ConvertFrom-Json).defaultProject } catch {} }
    try {
        Open-EnvWindow $name $proj
        $lblStatus.Text = "已开【$name】"
    }
    catch { [void][System.Windows.Forms.MessageBox]::Show("打开失败：$($_.Exception.Message)") }
})

$btnProj.Add_Click({
    $name = Selected-Env
    if (-not $name) { return }
    $proj = Pick-Folder "选环境【$name】默认打开的项目目录"
    if (-not $proj) { return }
    @{ defaultProject = $proj; createdAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') } |
        ConvertTo-Json | Set-Content (Join-Path $script:EnvsDir "$name\env-meta.json") -Encoding UTF8
    Refresh-UI
})

$btnDel.Add_Click({
    $name = Selected-Env
    if (-not $name) { return }
    $r = [System.Windows.Forms.MessageBox]::Show("删除环境【$name】？`n（含它的登录态和 VSCode 数据，不影响其它环境）", '确认删除',
        [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
    if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
        Remove-Item -LiteralPath (Join-Path $script:EnvsDir $name) -Recurse -Force -ErrorAction SilentlyContinue
        Refresh-UI
    }
})

$btnRefresh.Add_Click({ Refresh-UI })

Refresh-UI
[void]$form.ShowDialog()
