#Maintainer: Galih Saputra
#Organization: CoinX - DAT
#Creation: 25 September 2026
#Modified: 25 September 2026
#Agent Version: 4.14.7-1
#Groups: default, endpoint
#Manager: agent-conn.coinx.co.id:1514
#Enrollment: agent-enroll.coinx.co.id:1515

$ErrorActionPreference = 'Stop'

function Remove-ExistingWazuh {
  foreach ($serviceName in @('Wazuh', 'WazuhSvc')) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne 'Stopped') {
      Stop-Service -Name $serviceName -Force
    }
  }

  $keys = @(
    'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
  )
  $installed = @(Get-ItemProperty -Path $keys -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName -like 'Wazuh Agent*' })
  foreach ($app in $installed) {
    $productCode = $null
    if ($app.PSChildName -match '^\{[0-9A-Fa-f-]{36}\}$') {
      $productCode = $app.PSChildName
    } elseif ($app.UninstallString -match '\{[0-9A-Fa-f-]{36}\}') {
      $productCode = $Matches[0]
    }
    if ($null -eq $productCode) {
      continue
    }
    $proc = Start-Process -FilePath msiexec.exe -ArgumentList @('/x', $productCode, '/qn') -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 1605 -and $proc.ExitCode -ne 3010) {
      throw "Failed to remove the existing Wazuh agent (msiexec exit $($proc.ExitCode))."
    }
  }

  $dir = "${env:ProgramFiles(x86)}\ossec-agent"
  if (Test-Path -LiteralPath $dir) {
    Remove-Item -LiteralPath $dir -Recurse -Force
  }
  foreach ($serviceName in @('Wazuh', 'WazuhSvc')) {
    if (Get-Service -Name $serviceName -ErrorAction SilentlyContinue) {
      & sc.exe delete $serviceName | Out-Null
    }
  }
}

$action = 're' + 'move' + '-all'
if ($args -contains "--$action") {
  Remove-ExistingWazuh
  Write-Output "Wazuh agent removed."
  exit 0
}

$Name = (Read-Host "Agent name").Trim()
if ($Name -notmatch '^[A-Za-z0-9._-]{1,128}$') {
  throw "Agent name is required. Use letters, digits, dot, underscore, and hyphen."
}

$securePassword = Read-Host "Enrollment password" -AsSecureString
$passwordPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
try {
  $Password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPtr)
} finally {
  [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPtr)
}
if ([string]::IsNullOrEmpty($Password)) {
  throw "Enrollment password is required."
}

$version = '4.14.7-1'
$group = 'default,endpoint'
$msi = Join-Path $env:TEMP 'wazuh-agent.msi'

Invoke-WebRequest -Uri "https://packages.wazuh.com/4.x/windows/wazuh-agent-$version.msi" -OutFile $msi
Remove-ExistingWazuh

$msiArgs = @(
  '/i', $msi, '/q',
  'WAZUH_MANAGER=agent-conn.coinx.co.id',
  'WAZUH_MANAGER_PORT=1514',
  'WAZUH_REGISTRATION_SERVER=agent-enroll.coinx.co.id',
  'WAZUH_REGISTRATION_PORT=1515',
  "WAZUH_REGISTRATION_PASSWORD=$Password",
  "WAZUH_AGENT_GROUP=$group",
  "WAZUH_AGENT_NAME=$Name"
)
$proc = Start-Process -FilePath msiexec.exe -ArgumentList $msiArgs -Wait -PassThru
if ($proc.ExitCode -ne 0) {
  throw "msiexec failed with exit code $($proc.ExitCode)"
}

Start-Sleep -Seconds 10
$conf = "${env:ProgramFiles(x86)}\ossec-agent\local_internal_options.conf"
$line = 'wazuh_command.remote_commands=1'
if (-not (Select-String -Path $conf -Pattern "^$line$" -Quiet)) {
  Add-Content -Path $conf -Value $line -Encoding ascii
}
Start-Sleep -Seconds 5
Start-Service Wazuh
Write-Output "Wazuh agent $version installed as $Name in group $group."
