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
    [string]$BrokerServerName,

    [Parameter(Mandatory = $true)]
    [string]$LocalAdminUserName,

    [Parameter(Mandatory = $true)]
    [string]$LocalAdminPassword,

    [Parameter(Mandatory = $true)]
    [string]$ADServerName,

    [Parameter(Mandatory = $true)]
    [string]$SessionHostNames,

    [Parameter(Mandatory = $true)]
    [string]$GatewayExternalFqdn,

    [string]$WaitHandleBase64 = ""
)

$ErrorActionPreference = "Stop"

$BrokerFqdn = "$BrokerServerName.$DomainDNSName"
$DomainAdminCredential = New-Object -TypeName pscredential -ArgumentList (
    "$DomainNetBIOSName\$DomainAdminUserName",
    (ConvertTo-SecureString -String $DomainAdminPassword -AsPlainText -Force)
)
$LocalAdminSecurePassword = ConvertTo-SecureString -String $LocalAdminPassword -AsPlainText -Force
$SessionHosts = @($SessionHostNames.Split(",") | ForEach-Object { "{0}.{1}" -f $_.Trim(), $DomainDNSName })

function Invoke-SetupStage {
    Write-Host "Running setup stage..."

    # a-set-static-ip
    $netip = Get-NetIPConfiguration
    $ipconfig = Get-NetIPAddress | Where-Object { $_.IpAddress -eq $netip.IPv4Address.IpAddress }
    Get-NetAdapter | Set-NetIPInterface -DHCP Disabled
    Get-NetAdapter | New-NetIPAddress -AddressFamily IPv4 -IPAddress $netip.IPv4Address.IpAddress -PrefixLength $ipconfig.PrefixLength -DefaultGateway $netip.IPv4DefaultGateway.NextHop
    Get-NetAdapter | Set-DnsClientServerAddress -ServerAddresses $netip.DNSServer.ServerAddresses

    # b-join-domain
    Add-Computer -DomainName $DomainDNSName -Credential $DomainAdminCredential -NewName $BrokerServerName -Force

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

    # i-enable-credssp-client
    Enable-WSManCredSSP -Role Client -DelegateComputer $BrokerFqdn -Force

    # j-enable-credssp-registry
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation' -Name AllowFreshCredentialsWhenNTLMOnly -Value 1 -PropertyType Dword -Force
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation' -Name ConcatenateDefaults_AllowFreshNTLMOnly -Value 1 -PropertyType Dword -Force
    New-Item -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly' -Force
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CredentialsDelegation\AllowFreshCredentialsWhenNTLMOnly' -Name 1 -Value "WSMAN/$BrokerFqdn" -PropertyType String -Force

    # k-install-package-provider
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force

    # l-install-powershellget
    Install-Module -Name PowerShellGet -Force

    # m-install-rdwebclientmanagement
    Install-Module -Name RDWebClientManagement -Force -AcceptLicense

    # n-rename-local-admin
    Rename-LocalUser Administrator -NewName $LocalAdminUserName

    # o-reset-local-admin-pw
    Set-LocalUser $LocalAdminUserName -Password $LocalAdminSecurePassword

    # p-restart-computer
    Restart-Computer
}

function Invoke-DeployRdsStage {
    Write-Host "Running deployrds stage..."

    # a-create-rds-deployment
    Invoke-Command -ScriptBlock {
        param($ResolvedBrokerFqdn, $ResolvedSessionHosts)
        New-RDSessionDeployment -ConnectionBroker $ResolvedBrokerFqdn -WebAccessServer $ResolvedBrokerFqdn -SessionHost $ResolvedSessionHosts
    } -ArgumentList $BrokerFqdn, $SessionHosts -Credential $DomainAdminCredential -ComputerName $BrokerFqdn -Authentication Credssp

    # b-install-gateway-feature
    Install-WindowsFeature -Name RDS-Gateway -IncludeManagementTools

    # c-add-gateway-server
    Add-RDServer -Server $BrokerFqdn -Role 'RDS-GATEWAY' -ConnectionBroker $BrokerFqdn -GatewayExternalFqdn $BrokerFqdn

    # d-add-licensing-server
    Add-RDServer -Server $BrokerFqdn -Role 'RDS-LICENSING' -ConnectionBroker $BrokerFqdn

    # e-set-license-configuration
    Set-RDLicenseConfiguration -LicenseServer $BrokerFqdn -Mode PerUser -ConnectionBroker $BrokerFqdn -Force

    # f-activate-license-server
    $wmiClass = ([wmiclass]'\\localhost\root\cimv2:Win32_TSLicenseServer')
    $wmiTSLicenseObject = Get-WMIObject Win32_TSLicenseServer
    $wmiTSLicenseObject.FirstName = 'Test'
    $wmiTSLicenseObject.LastName = 'Inc'
    $wmiTSLicenseObject.Company = 'Test Inc'
    $wmiTSLicenseObject.CountryRegion = 'United States'
    $null = $wmiTSLicenseObject.Put()
    $null = $wmiClass.ActivateServerAutomatic()
    $wmiClass.GetActivationStatus().ActivationStatus
    Write-Host '(0 = activated, 1 = not activated)'

    # g-add-license-server-to-ad
    Invoke-Command -ScriptBlock {
        param($ResolvedBrokerServerName)
        Add-ADGroupMember -Identity 'Terminal Server License Servers' -Members (Get-ADComputer -Identity $ResolvedBrokerServerName)
    } -ArgumentList $BrokerServerName -ComputerName $ADServerName -Credential $DomainAdminCredential

    # h-install-rdwebclientpackage
    Install-RDWebClientPackage

    # i-unpack-winacme-module
    Expand-Archive -Path 'c:\cfn\win-acme.zip' -DestinationPath 'c:\cfn\win-acme\' -Force

    # j-generate-ssl-cert
    & 'c:\cfn\win-acme\wacs.exe' --source manual --host $GatewayExternalFqdn --certificatestore My --installation iis,script --installationsiteid 1 --script 'C:\cfn\win-acme\Scripts\ImportRDSFull.ps1' --scriptparameters '{CertThumbprint}' --emailaddress support@netcov.com --accepttos

    # k-new-rds-collection
    Invoke-Command -ScriptBlock {
        param($ResolvedSessionHosts)
        New-RDSessionCollection -CollectionName 'RemoteApps' -CollectionDescription 'Session collection for remote applications and desktops' -SessionHost $ResolvedSessionHosts
    } -ArgumentList $SessionHosts -Credential $DomainAdminCredential -ComputerName $BrokerFqdn -Authentication Credssp

    # l-set-rds-collection
    Invoke-Command -ScriptBlock {
        param($ResolvedBrokerFqdn)
        Set-RDSessionCollectionConfiguration -CollectionName 'RemoteApps' -ClientDeviceRedirectionOptions TimeZone -MaxRedirectedMonitors 16 -ClientPrinterRedirected $false -TemporaryFoldersPerSession $true -BrokenConnectionAction Disconnect -TemporaryFoldersDeletedOnExit $true -AutomaticReconnectionEnabled $true -ActiveSessionLimitMin 960 -DisconnectedSessionLimitMin 5 -IdleSessionLimitMin 480 -AuthenticateUsingNLA $true -EncryptionLevel High -SecurityLayer Negotiate -ConnectionBroker $ResolvedBrokerFqdn
    } -ArgumentList $BrokerFqdn -Credential $DomainAdminCredential -ComputerName $BrokerFqdn -Authentication Credssp
}

function Set-ConfigureServerManagerRunOnce {
    $runOncePath = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce'

    # This script body mirrors the PowerShell embedded in c:\cfn\configureservermanager.bat.
    $configureServerManagerCommand = "powershell.exe -command ""Start-Process `$env:windir\system32\ServerManager.exe; Start-Sleep 5; if ((Get-Process).ProcessName -contains 'ServerManager') {Get-Process ServerManager | Stop-Process -Force}; `$file = Get-Item `$env:USERPROFILE\AppData\Roaming\Microsoft\Windows\ServerManager\ServerList.xml; Copy-Item -Path `$file.FullName -Destination `$file-backup -Force; `$xml = [xml] (Get-Content `$file); `$newserver = @(`$xml.ServerList.ServerInfo)[0].clone(); `$newserver.Name = '$BrokerFqdn'; `$newserver.LastUpdateTime = '0001-01-01T00:00:00'; `$newserver.Status = '2'; `$xml.ServerList.AppendChild(`$newserver); `$xml.Save(`$file.FullName); Start-Process `$env:windir\system32\ServerManager.exe;"""

    New-Item -Path $runOncePath -Force
    New-ItemProperty -Path $runOncePath -Name ConfigureServerManager -Value 'c:\cfn\temp\configureservermanager.bat'

    [pscustomobject]@{
        RunOncePath = $runOncePath
        ConfigureServerManagerCommand = $configureServerManagerCommand
    }
}

function Invoke-FinalizeStage {
    Write-Host "Running finalize stage..."

    # a-publish-rdwebclientpackage
    Publish-RDWebClientPackage -Type Production -Latest

    # b-add-run-once and c-configure-run-once
    Set-ConfigureServerManagerRunOnce | Out-Null

    # d-signal-success
    if ($WaitHandleBase64) {
        & 'cfn-signal.exe' -e 0 $WaitHandleBase64
    }
}

Write-Host "Extracted commands from NetCov-RD-BK-Stack.template into reusable PowerShell functions."
Write-Host "Call Invoke-SetupStage, Invoke-DeployRdsStage, and Invoke-FinalizeStage as needed."
