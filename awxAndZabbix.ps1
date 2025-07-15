function Log {
    param([string]$Message)
    Write-Host "$(Get-Date -Format 'u') - $Message"
}
function Ensure-Admin {
    if (-NOT ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")) {
        Write-Host "Requesting administrator privileges..." -ForegroundColor Yellow
        # Relaunch with -NoExit so the window stays open after execution
        Start-Process powershell "-NoExit -ExecutionPolicy Bypass -File `"$($MyInvocation.MyCommand.Path)`"" -Verb RunAs
        Read-Host "Press Enter to exit"
        exit 0
    }
}

function WaitOnError {
    param([string]$ErrorMessage)
    Log $ErrorMessage
    Write-Host "Press Enter to exit..."
    [void][System.Console]::ReadLine()
    exit 1
}

function Update-ZabbixConfig {
    param([string]$ServerIp)
    $confPath = "C:\Program Files\Zabbix Agent\conf\zabbix_agentd.conf"
    try {
        if (Test-Path $confPath) {
            $conf = Get-Content $confPath
            $conf = $conf -replace '^(Server=).*', "Server=$ServerIp"
            $conf = $conf -replace '^(ServerActive=).*', "ServerActive=$ServerIp"
            Set-Content -Path $confPath -Value $conf -Force
            Log "Updated Zabbix Server IP and ServerActive to $ServerIp in $confPath"
            $service = Get-Service -Name "Zabbix Agent" -ErrorAction SilentlyContinue
            if ($null -eq $service) {
                throw "Zabbix Agent service not found."
            } elseif ($service.Status -eq 'Running') {
                Restart-Service -Name "Zabbix Agent" -Force
                Log "Restarted Zabbix Agent service."
            } elseif ($service.Status -eq 'Stopped') {
                Start-Service -Name "Zabbix Agent"
                Log "Started Zabbix Agent service."
            } else {
                throw "Zabbix Agent service is in an unexpected state: $($service.Status)"
            }
        } else {
            throw "Zabbix config not found at $confPath"
        }
    } catch {
        throw "Failed to update Zabbix config: $_"
    }
}


function Add-LocalFirewallRules {
    try {
        Log "Adding local firewall rules for ICMPv4 and Zabbix Agent Passive..."
        netsh advfirewall firewall add rule name="Allow ICMPv4-In (Local)" protocol=icmpv4:8,any dir=in action=allow remoteip=localsubnet | Out-Null
        netsh advfirewall firewall add rule name="Zabbix Agent Passive In (Local)" dir=in action=allow protocol=TCP localport=10050 remoteip=localsubnet | Out-Null
        Log "Added firewall rules for ICMPv4 and Zabbix Agent Passive."
    } catch {
        throw "Failed to add local firewall rules: $_"
    }
}

function Configure-WinRM {
    try {
        Log "Enabling and configuring WinRM for AWX..."
        winrm quickconfig -force | Out-Null
        winrm set winrm/config/service/auth '@{Basic="true"}' | Out-Null
        winrm set winrm/config/service '@{AllowUnencrypted="true"}' | Out-Null
        if (-not (winrm enumerate winrm/config/Listener | Select-String "Transport = HTTP")) {
            winrm create winrm/config/Listener?Address=*+Transport=HTTP | Out-Null
        }
        Set-Item -Path WSMan:\localhost\Service\AllowRemoteAccess -Value $true
        if (-not (Get-NetFirewallRule -DisplayName "WinRM HTTP" -ErrorAction SilentlyContinue)) {
            New-NetFirewallRule -Name "WinRM_HTTP" -DisplayName "WinRM HTTP" -Protocol TCP -LocalPort 5985 -Action Allow | Out-Null
        }
        Log "WinRM is configured for AWX."
    } catch {
        throw "Failed to configure WinRM: $_"
    }
}

function Get-ZabbixServerIpFromHostname {
    $hostname = $env:COMPUTERNAME
    # Extract number from hostname (e.g., BUZZ-0 -> 0)
    if ($hostname -match '\d+$') {
        $num = [int]($Matches[0])
        # Map number ranges to dummy Zabbix server IPs
        if ($num -ge 0 -and $num -le 50) {
            return "10.1.1.168"  # Dummy IP for 0-50
        } elseif ($num -ge 51 -and $num -le 100) {
            return "10.1.2.232"  # Dummy IP for 51-100
        } elseif ($num -ge 101 -and $num -le 150) {
            return "10.1.3.85"  # Dummy IP for 101-150
        } elseif ($num -ge 151 -and $num -le 200) {
            return "10.1.4.250"  # Dummy IP for 151-200
        } elseif ($num -ge 201 -and $num -le 250) {
            return "10.1.5.148"  # Dummy IP for 201-250
        } elseif ($num -ge 251 -and $num -le 300) {
            return "10.1.6.112"  # Dummy IP for 251-300
        } elseif ($num -ge 301 -and $num -le 350) {
            return "10.1.7.252"  # Dummy IP for 301-350
        } else {
            throw "unknown"  # Default dummy IP
        }
    } else {
        # Default IP if no number found
        throw "unknown"  # Default dummy IP
    }
}

# --- Main Script ---
try {
    Ensure-Admin
    $ZabbixServerIp = Get-ZabbixServerIpFromHostname
    Log "Determined ZabbixServerIp: $ZabbixServerIp"
    Log "Starting Zabbix and WinRM configuration..."
    Update-ZabbixConfig -ServerIp $ZabbixServerIp
    Configure-WinRM
    Add-LocalFirewallRules
    Log "All tasks completed successfully."
} catch {
    WaitOnError "Unexpected error: $_"
}
Read-Host "Press Enter to exit"
