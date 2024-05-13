Add-Type -AssemblyName System.IO.Compression.FileSystem
Import-Module WebAdministration

$WebName = "TestSite"
$WebPool = $WebName + "Pool"
$Temp = "$PSScriptRoot\temp"
$WebPath="$Temp\$WebName"
$BindingInfo = @{
    Protocol = "https"
    Port = 443
}
$GroupName = $WebName + "Group"
$UserName = $WebName + "User"

if(Test-Path $Temp)
{
    Write-Host "Removing $Temp."
	Remove-Item -Path $Temp -Force -Recurse
}
New-Item -ItemType Directory -Path "$Temp"
$PwdFile = "$Temp\pwd.txt"
# Request a password for the new user
Read-Host "Enter Password (this will be used to create $UserName later.)" -AsSecureString | ConvertFrom-SecureString | Out-File $PwdFile
$ApplicationName = "HelloWorld"
$ApplicationPoolName = $ApplicationName + "Pool"
$LogFilePath = "C:\inetpub\logs\LogFiles\W3SVC1\u_extend1.log"
$OthersPath = "$PSScriptRoot\others"
$CertPath = "$OthersPath\cert.pfx"
$fqdn = "devopstest.com"

Write-Host "$WebName will install to $WebPath"
Write-Host "After installation, you can visit the site with https://$fqdn"
Write-Host "Installation started. Press Ctrl+C to stop."

Write-Host "Checking IIS status..."
$iis = Get-Service W3SVC -ErrorAction Ignore
if($iis){
    if($iis.Status -eq "Running") {
        Write-Host "IIS Service is running"
    }
    else {
        Write-Host "IIS Service is not running"
    }
}
else {
	Write-Host "Checking IIS failed, please make sure IIS is ready."	
}
$aspNetCoreModule = Get-WebGlobalModule -Name AspNetCoreModule* -ErrorAction Ignore
if($aspNetCoreModule)
{
	Write-Host "IIS ASPNetCoreModule is ready:"
	Write-Host $aspNetCoreModule.Name $aspNetCoreModule.Image 
}
else
{
	Write-Host "Downloading DotNetCore.WindowsHosting."
	if(Test-Path -Path "DotNetCore.WindowsHosting.exe")
	{
		Remove-Item -Path "DotNetCore.WindowsHosting.exe" -Force
	}
	Invoke-WebRequest -Uri "https://aka.ms/dotnetcore.2.0.0-windowshosting" -OutFile "DotNetCore.WindowsHosting.exe"
	
	Write-Host "Installing DotNetCore.WindowsHosting."
	Start-Process "DotNetCore.WindowsHosting.exe" -Wait -ArgumentList '/S', '/v', '/qn' -passthru
	if(Test-Path -Path "DotNetCore.WindowsHosting.exe")
	{
		Remove-Item -Path "DotNetCore.WindowsHosting.exe" -Force
	}
}

Write-Host "Creating $WebPath and index.html file..."
New-Item -ItemType Directory -Path "$WebPath"
New-Item -ItemType File -Path "$WebPath\index.html"
Set-Content -Path "$WebPath\index.html" -Value "Hello, World!"

Write-Host "Setting up IIS."
if(!(Test-Path IIS:\AppPools\$WebPool))
{
	New-Item -path IIS:\AppPools\$WebPool
}

Write-Host "Creating $WebPool AppPool ."
Set-ItemProperty -Path IIS:\AppPools\$WebPool -Name managedRuntimeVersion -Value ''

if(Test-Path IIS:\Sites\$WebName)
{
    Write-Host "Removing old $WebName."
	Remove-Website $WebName
}

# Create IIS website binding with https
Write-Host "Creating IIS $WebName website binding with https."
New-Website -name $WebName -PhysicalPath $WebPath -ApplicationPool $WebPool -ssl -Port $BindingInfo.Port  -IPAddress '*'

# Download others files from github
<#
if(Test-Path -Path "$OthersPath")
{
	Remove-Item -Path "$OthersPath" -Force -Recurse
}
New-Item -ItemType Directory -Path "$OthersPath"
Invoke-Expression "git init $OthersPath"
Set-Content $OthersPath\.git\info\sparse-checkout "others/*" -Encoding Ascii
Invoke-Expression "cd $OthersPath | git remote add origin https://github.com/AmyInGit/DevOpsTestLab.git | git config core.sparsecheckout true | git pull origin main"
#>

# Add SSL Certificate
Write-Host "Adding SSL Certificate"
$pwd = ConvertTo-SecureString -String "654321" -Force -AsPlainText
Import-PfxCertificate -FilePath $CertPath -CertStoreLocation 'Cert:\LocalMachine\My' -Password $pwd -Verbose
$cert = Get-ChildItem cert:\LocalMachine\MY | Where-Object { $_.Subject -like "*devopstest*" }
$NewBinding = Get-WebBinding -Name "$WebName" -protocol $BindingInfo.Protocol
$NewBinding.AddSSLCertificate("$($cert.getcerthashstring())", "MY")

Invoke-Expression "net stop was /y"
Invoke-Expression "net start w3svc"
Invoke-Expression "cmd.exe /C start https://$fqdn"


Write-Host "Adding $fqdn into hosts file"
$hostPath = 'C:\Windows\System32\drivers\etc\hosts'
$hostFile = Get-Content $hostPath
$hostEntry = "127.0.0.1 `t $fqdn"
Add-content -path $hostPath -value $hostEntry
ipconfig /flushdns

Write-Host "Creating $GroupName and $UserName"
# Create a local group and add a user as a group member
New-LocalGroup -Name $GroupName
$password = Get-Content $PwdFile | ConvertTo-SecureString
New-LocalUser $UserName -FullName $UserName -Password ($password)
net user $UserName /active:yes
Add-LocalGroupMember -Group $GroupName -Member $UserName

# Create an application pool in IIS and run it with the specified user
Write-Host "Creating $ApplicationPoolName application pool"
if(!(Test-Path IIS:\AppPools\$ApplicationPoolName))
{
	New-WebAppPool -Name $ApplicationPoolName
}

$BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($password)
$plainPassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
Set-ItemProperty "IIS:\AppPools\$ApplicationPoolName" -Name processModel -Value @{identityType="SpecificUser";userName="$userName";password=($plainPassword)}

# Modify the path of the website log file
Write-Host "Updating $WebName logpath to $LogFilePath."
Set-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='$WebName']/logFile" -Name "directory" -Value $LogFilePath

# Create an application under the website and bind it to the application pool
Write-Host "Unzip $ApplicationName application package."
[System.IO.Compression.ZipFile]::ExtractToDirectory("$OthersPath\$ApplicationName.1.0.0.zip" ,"$WebPath\$ApplicationName")

Write-Host "Adding $ApplicationName application into $WebName."
New-WebApplication -Name $ApplicationName -Site $WebName -PhysicalPath "$WebPath\$ApplicationName" -ApplicationPool $ApplicationPoolName

Invoke-Expression "net stop was /y"
Invoke-Expression "net start w3svc"
Invoke-Expression "cmd.exe /C start https://$fqdn/$ApplicationName"

Write-Host "$WebName with $ApplicationName application installed successfully."
