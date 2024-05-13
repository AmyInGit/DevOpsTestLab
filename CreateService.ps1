# Define variables
$serviceName = "TestService"
$serviceDisplayName = "Test Windows Service"
$serviceDescription = "This is a sample Windows service."
$executablePath = "$PSScriptRoot\others\TestService.exe"
$username = "$env:UserDomain\TestSiteUser"
$password = Get-Content $PSScriptRoot\temp\pwd.txt | ConvertTo-SecureString
$Cred = New-Object System.Management.Automation.PSCredential ($username, $password)
$serviceStartMode = "Automatic"

function Add-RightToUser([string] $Username, $Right) {
    $tmp = New-TemporaryFile

    $TempConfigFile = "$tmp.inf"
    $TempDbFile = "$tmp.sdb"

    Write-Host "Getting current policy"
    secedit /export /cfg $TempConfigFile

    $sid = ((New-Object System.Security.Principal.NTAccount($Username)).Translate([System.Security.Principal.SecurityIdentifier])).Value

    $currentConfig = Get-Content -Encoding ascii $TempConfigFile

    $newConfig = $null

    if ($currentConfig | Select-String -Pattern "^$Right = ") {
        if ($currentConfig | Select-String -Pattern "^$Right .*$sid.*$") {
            Write-Host "Already has right"
        }
        else {
            Write-Host "Adding $Right to $Username"

            $newConfig = $currentConfig -replace "^$Right .+", "`$0,*$sid"
        }
    }
    else {
        Write-Host "Right $Right did not exist in config. Adding $Right to $Username."

        $newConfig = $currentConfig -replace "^\[Privilege Rights\]$", "`$0`n$Right = *$sid"
    }

    if ($newConfig) {
        Set-Content -Path $TempConfigFile -Encoding ascii -Value $newConfig

        Write-Host "Validating configuration"
        $validationResult = secedit /validate $TempConfigFile

        if ($validationResult | Select-String '.*invalid.*') {
            throw $validationResult;
        }
        else {
            Write-Host "Validation Succeeded"
        }

        Write-Host "Importing new policy on temp database"
        secedit /import /cfg $TempConfigFile /db $TempDbFile

        Write-Host "Applying new policy to machine"
        secedit /configure /db $TempDbFile /cfg $TempConfigFile

        Write-Host "Updating policy"
        gpupdate /force

        Remove-Item $tmp* -ea 0
    }
}

# Create a new Windows service
Write-Host "Creating new service $serviceName"
New-Service -Name $serviceName -DisplayName $serviceDisplayName -Description $serviceDescription -BinaryPathName $executablePath -startupType $serviceStartMode -credential $Cred

# Grant SeServiceLogonRight permission to TestSiteUser
Add-RightToUser -Username "$username" -Right 'SeServiceLogonRight'

# Set the service recovery options
Write-Host "Updating service recovery options to recover every 60 seconds."
sc.exe failure $serviceName reset=86400 actions=restart/60000
sc.exe qfailure $serviceName
sc.exe start $serviceName

Write-Host "Set service $serviceName successfully."

