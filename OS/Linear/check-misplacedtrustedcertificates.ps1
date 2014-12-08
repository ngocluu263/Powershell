# Checks for trusted certs either misplaced or duplicated between the intermediate and trusted root stores

$rootcerts = Get-Childitem 'cert:\LocalMachine\root' -Recurse 
$misplacedrootcerts = $rootcerts | Where-Object {$_.Issuer -ne $_.Subject}
$intermediatecerts = Get-Childitem 'cert:\LocalMachine\CA' -Recurse | Where {$_.Subject -ne 'CN=Root Agency'}
$misplacedintermediatecerts = $intermediatecerts | Where-Object {$_.Issuer -eq $_.Subject}

Foreach ($cert in $misplacedrootcerts) {
    if (($intermediatecerts).thumbprint -contains $cert.thumbprint) {
        Write-Host -ForegroundColor:Yellow "Intermediate cert found duplicated in root cert store - $($cert.Subject)"
        Write-Host -ForegroundColor:Magenta "Recommended action: Delete certificate from trusted root store."
        Write-Host -ForegroundColor:DarkMagenta '**Certificate Details **'
        Write-Host -ForegroundColor:DarkMagenta $cert
    }
    else {
        Write-Host -ForegroundColor:Yellow "Intermediate cert found in root cert store - $($cert.Subject)"
        Write-Host -ForegroundColor:Magenta "Recommended action: Move certificate from trusted root store to intermediate store."
        Write-Host -ForegroundColor:DarkMagenta '**Certificate Details **'
        Write-Host -ForegroundColor:DarkMagenta $cert
    }
}

Foreach ($cert in $misplacedintermediatecerts) {
    if (($rootcerts).thumbprint -contains $cert.thumbprint) {
        Write-Host -ForegroundColor:Yellow "Trusted root cert found duplicated in intermediate cert store - $($cert.Subject)"
        Write-Host -ForegroundColor:Magenta "Recommended action: Delete certificate from intermediate store."
        Write-Host -ForegroundColor:DarkMagenta '**Certificate Details **'
        Write-Host -ForegroundColor:DarkMagenta $cert
    }
    else {
        Write-Host -ForegroundColor:Yellow "Trusted root cert found in intermediate cert store - $($cert.Subject)"
        Write-Host -ForegroundColor:Magenta "Recommended action: Move certificate from intermediate cert store to root cert store."
        Write-Host -ForegroundColor:DarkMagenta '**Certificate Details **'
        Write-Host -ForegroundColor:DarkMagenta $cert
    }
}