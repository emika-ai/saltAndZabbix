# Check for admin rights
function Ensure-Admin {
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
        # Relaunch with -NoExit so the window stays open after execution
        Start-Process powershell "-NoExit -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
        Read-Host "Press Enter to exit"
        exit 0
    }
}

# Variables - change these according to your environment
$saltMaster = "23.88.86.116"
$zabbixServer = "23.88.86.116"

# Paths to installers (you can replace URLs with local file paths if needed)
$saltInstallerUrl = "https://packages.broadcom.com/artifactory/saltproject-generic/windows/3007.4/Salt-Minion-3007.4-Py3-AMD64.msi"
$zabbixZipUrl = "https://cdn.zabbix.com/zabbix/binaries/stable/7.4/7.4.0/zabbix_agent-7.4.0-windows-amd64.zip"


# Temporary paths for installers
$downloads = [Environment]::GetFolderPath("MyDocuments").Replace("Documents", "Downloads")
$saltInstallerPath = Join-Path $downloads "Salt-Minion-Setup.msi"
$zabbixZipPath = Join-Path $downloads "zabbix_agent.zip"
$zabbixExtractPath = "C:\Program Files\Zabbix Agent"
$zabbixBinPath = Join-Path $zabbixExtractPath "bin"
$zabbixConfPath = Join-Path $zabbixExtractPath "conf\zabbix_agentd.conf"
$zabbixAgentExe = Join-Path $zabbixBinPath "zabbix_agentd.exe"

Write-Output "Salt Minion installer path: $saltInstallerPath"
Write-Output "Zabbix Agent zip path: $zabbixZipPath"
Write-Output "Zabbix Agent extract path: $zabbixExtractPath"


function Download-Installer {
    param(
        [string]$url,
        [string]$outFile,
        [string]$name
    )
    if (Test-Path $outFile) {
        Write-Output "$name already exists at $outFile. Skipping download."
    } else {
        Write-Output "Downloading $name..."
        try {
            Invoke-WebRequest -Uri $url -OutFile $outFile -TimeoutSec 120
        } catch {
            Write-Error "Failed to download $name from $url. Error: $_"
            Write-Host "Press Enter to exit..."
            [void][System.Console]::ReadLine()
            throw
        }
    }
}

function Extract-Zip {
    param(
        [string]$zipPath,
        [string]$extractPath
    )
    if (Test-Path $extractPath) {
        Write-Output "Zabbix Agent already extracted at $extractPath. Skipping extraction."
    } else {
        Write-Output "Extracting Zabbix Agent zip to $extractPath..."
        if (!(Test-Path $extractPath)) {
            New-Item -Path $extractPath -ItemType Directory -Force | Out-Null
        }
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force
    }
}

function Install-SaltMinion {
    param(
        [string]$installerPath,
        [string]$saltMaster
    )
    # Check if Salt Minion is already installed
    $existingSalt = Get-Service -Name "salt-minion" -ErrorAction SilentlyContinue
    if ($existingSalt) {
        Write-Output "Salt Minion is already installed. Skipping installation."
        return
    }
    Write-Output "Installing Salt Minion..."
    $process = Start-Process msiexec.exe -ArgumentList "/i `"$installerPath`" /quiet /norestart" -Wait -PassThru
    Write-Output "Salt Minion installer exited with code: $($process.ExitCode)"
    if ($process.ExitCode -ne 0) {
        throw "Salt Minion installer failed with exit code $($process.ExitCode)"
    }
    # Try both common config paths
    $possibleConfPaths = @(
        "C:\\ProgramData\\Salt Project\\Salt\\conf\\minion",
        "C:\\Salt\\conf\\minion"
    )
    $saltConfPath = $null
    foreach ($path in $possibleConfPaths) {
        if (Test-Path (Split-Path $path)) {
            $saltConfPath = $path
            break
        }
    }
    if (-not $saltConfPath) {
        # Default to ProgramData if neither exists
        $saltConfPath = "C:\\ProgramData\\Salt Project\\Salt\\conf\\minion"
        $confDir = Split-Path $saltConfPath
        if (!(Test-Path $confDir)) {
            New-Item -Path $confDir -ItemType Directory -Force | Out-Null
        }
    }
    Write-Output "Configuring Salt Minion to use master: $saltMaster in $saltConfPath"
    # Set custom minion ID (change $minionId as needed)
    $minionId = $env:COMPUTERNAME  # or set to any string you want
    Set-Content -Path $saltConfPath -Value @" 
master: $saltMaster
id: $minionId
"@
    Write-Output "Starting Salt Minion service..."
    Start-Service salt-minion
    Set-Service salt-minion -StartupType Automatic
}

function Install-ZabbixAgent {
    param(
        [string]$zipPath,
        [string]$extractPath,
        [string]$zabbixServer
    )
    # Check if Zabbix Agent is already running
    $existingZabbix = Get-Service -Name "Zabbix Agent" -ErrorAction SilentlyContinue
    if ($existingZabbix) {
        Write-Output "Zabbix Agent is already installed. Skipping installation."
        return
    }
    Extract-Zip -zipPath $zipPath -extractPath $extractPath
    if (!(Test-Path $zabbixAgentExe)) {
        throw "zabbix_agentd.exe not found in bin folder after extraction."
    }
    if (!(Test-Path $zabbixConfPath)) {
        throw "zabbix_agentd.conf not found in conf folder after extraction."
    }
    Write-Output "Installing Zabbix Agent as a service..."
    $installCmd = "--config `"$zabbixConfPath`" --install"
    $process = Start-Process -FilePath $zabbixAgentExe -ArgumentList $installCmd -Wait -PassThru -WorkingDirectory $zabbixBinPath
    Write-Output "Zabbix Agent install command exited with code: $($process.ExitCode)"
    if ($process.ExitCode -ne 0) {
        throw "Zabbix Agent install command failed with exit code $($process.ExitCode)"
    }
    # Configure Zabbix Agent config file
    Write-Output "Configuring Zabbix Agent to connect to server: $zabbixServer"
    # Backup original config
    Copy-Item -Path $zabbixConfPath -Destination "$zabbixConfPath.bak" -Force
    # Update Server, ServerActive, and Hostname parameters in config (case-insensitive)
    $hostname = $env:COMPUTERNAME
    (Get-Content $zabbixConfPath) `
        -replace '(?i)^Server=.*', "Server=$zabbixServer" `
        -replace '(?i)^ServerActive=.*', "ServerActive=$zabbixServer" `
        -replace '(?i)^Hostname=.*', "Hostname=$hostname" |
        Set-Content $zabbixConfPath
    # Start and set Zabbix Agent service to automatic
    Write-Output "Starting Zabbix Agent service..."
    Start-Process -FilePath $zabbixAgentExe -ArgumentList "--start" -WorkingDirectory $zabbixBinPath
    Set-Service -Name "Zabbix Agent" -StartupType Automatic
}


function Main {
    try {
        Ensure-Admin
        Download-Installer -url $zabbixZipUrl -outFile $zabbixZipPath -name "Zabbix Agent zip"
        Install-ZabbixAgent -zipPath $zabbixZipPath -extractPath $zabbixExtractPath -zabbixServer $zabbixServer
        Download-Installer -url $saltInstallerUrl -outFile $saltInstallerPath -name "Salt Minion"
        Install-SaltMinion -installerPath $saltInstallerPath -saltMaster $saltMaster
        Write-Output "SaltStack and Zabbix agents installation and configuration complete."
    } catch {
        Write-Error "An error occurred: $_"
        Write-Host "Press Enter to exit..."
        [void][System.Console]::ReadLine()
    }
}

Main
