[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$DomainDNSName,

    [Parameter(Mandatory = $true)]
    [string]$DomainNetBIOSName,

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminUserName,

    [Parameter(Mandatory = $true)]
    [string]$DomainAdminPassword,

    [Parameter(Mandatory = $true)]
    [string]$VmName,

    [Parameter(Mandatory = $true)]
    [string]$LocalAdminUserName,

    [Parameter(Mandatory = $true)]
    [string]$LocalAdminPassword
)

$ErrorActionPreference = "Stop"

$DomainAdminCredential = New-Object -TypeName pscredential -ArgumentList (
    "$DomainNetBIOSName\$DomainAdminUserName",
    (ConvertTo-SecureString -String $DomainAdminPassword -AsPlainText -Force)
)
$LocalAdminSecurePassword = ConvertTo-SecureString -String $LocalAdminPassword -AsPlainText -Force

function Invoke-SessionHostConfigStage {
    Write-Host "Running session host config stage..."

    # a-set-static-ip
    $netip = Get-NetIPConfiguration
    $ipconfig = Get-NetIPAddress | Where-Object { $_.IpAddress -eq $netip.IPv4Address.IpAddress }
    Get-NetAdapter | Set-NetIPInterface -DHCP Disabled
    Get-NetAdapter | New-NetIPAddress -AddressFamily IPv4 -IPAddress $netip.IPv4Address.IpAddress -PrefixLength $ipconfig.PrefixLength -DefaultGateway $netip.IPv4DefaultGateway.NextHop
    Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $netip.DNSServer.ServerAddresses

    # b-join-domain
    Add-Computer -DomainName $DomainDNSName -Credential $DomainAdminCredential -NewName $VmName -Force

    # c-remove-windows-defender
    Remove-WindowsFeature -Name Windows-Defender

    # d-enable-remotefx
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services' -Name 'fEnableRemoteFXAdvancedRemoteApp' -Value 0 -PropertyType DWORD -Force

    # e-turn-off-uac
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'ConsentPromptBehaviorAdmin' -Value 0

    # f-turn-off-windows-firewall
    Set-NetFirewallProfile -All -Enabled False

    # g-enable-powershell-remoting
    Enable-PSRemoting

    # h-enable-credssp-server
    Enable-WSManCredSSP -Role Server -Force

    # i-rename-local-admin
    Rename-LocalUser Administrator -NewName $LocalAdminUserName

    # j-reset-local-admin-pw
    Set-LocalUser $LocalAdminUserName -Password $LocalAdminSecurePassword

    # k-restart-computer
    Restart-Computer
}

Write-Host "Extracted commands from NetCov-RD-SH-Stack.template into reusable PowerShell functions."
Write-Host "Call Invoke-SessionHostConfigStage as needed."
