#requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests for the pure (no Azure) functions in scripts/ops/AvdLandingZone.psm1.
# Run: Invoke-Pester ./build/tests

BeforeAll {
  Import-Module (Join-Path $PSScriptRoot '../../scripts/ops/AvdLandingZone.psm1') -Force
}

Describe 'ConvertTo-AvdEntraSid' {
  It 'matches the Microsoft-published object ID to SID example' {
    ConvertTo-AvdEntraSid '73d664e4-0886-4a73-b745-c694da45ddb4' |
      Should -Be 'S-1-12-1-1943430372-1249052806-2496021943-3034400218'
  }
}

Describe 'Profile share ACL evaluation' {
  BeforeAll {
    $users = 'S-1-12-1-1-2-3-4'
    $admins = 'S-1-12-1-5-6-7-8'
    $desired = Get-AvdDesiredShareSddl -UsersSid $users -AdminsSid $admins
    # Typical root ACL of a new Azure Files share.
    $default = 'O:SYG:SYD:(A;OICIIO;GA;;;CO)(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;;0x1301bf;;;AU)(A;OICIIO;SDGXGWGR;;;AU)(A;OICI;0x1200a9;;;BU)'
  }

  It 'accepts the ACL it generates' {
    (Test-AvdShareSddl -Sddl $desired -UsersSid $users -AdminsSid $admins).Count | Should -Be 0
  }

  It 'flags the default share ACL' {
    $issues = Test-AvdShareSddl -Sddl $default -UsersSid $users -AdminsSid $admins
    $issues | Should -Contain 'Inheritance from the share default is not disabled (DACL not protected).'
    $issues | Should -Contain 'Authenticated Users can write to the share root.'
    ($issues -join ' ') | Should -Match 'AVD Users group has no entry'
    ($issues -join ' ') | Should -Match 'AVD Admins group does not have full control'
    ($issues -join ' ') | Should -Not -Match 'BUILTIN'
  }

  It 'flags a users entry that inherits into profile folders' {
    $leaky = $desired.Replace("(A;;0x1301bf;;;$users)", "(A;OICI;0x1301bf;;;$users)")
    (Test-AvdShareSddl -Sddl $leaky -UsersSid $users -AdminsSid $admins) -join ' ' | Should -Match 'each other'
  }
}

Describe 'Test-AvdAceGrantsWrite' {
  It '<Rights> grants write: <Expected>' -TestCases @(
    @{ Rights = '0x1301bf'; Expected = $true }
    @{ Rights = '0x1200a9'; Expected = $false }
    @{ Rights = 'GXGR'; Expected = $false }
    @{ Rights = 'SDGXGWGR'; Expected = $true }
    @{ Rights = 'FA'; Expected = $true }
  ) {
    Test-AvdAceGrantsWrite $Rights | Should -Be $Expected
  }
}

Describe 'Get-AvdRandomPassword' {
  It 'returns a read-only 24-character SecureString meeting Windows complexity' {
    $pw = Get-AvdRandomPassword
    $pw.IsReadOnly() | Should -BeTrue
    $plain = [System.Net.NetworkCredential]::new('', $pw).Password
    $plain.Length | Should -Be 24
    $plain | Should -MatchExactly '[A-Z]'
    $plain | Should -MatchExactly '[a-z]'
    $plain | Should -Match '\d'
    $plain | Should -Match '[^A-Za-z0-9]'
  }
  It 'differs between calls' {
    $a = [System.Net.NetworkCredential]::new('', (Get-AvdRandomPassword)).Password
    $b = [System.Net.NetworkCredential]::new('', (Get-AvdRandomPassword)).Password
    $a | Should -Not -Be $b
  }
}

Describe 'Get-AvdGraphFilterUri' {
  It 'URL-encodes the filter' {
    Get-AvdGraphFilterUri -Collection applications -Filter "displayName eq '[Storage Account] st1.file.core.windows.net'" -Select 'id,appId' |
      Should -Be 'v1.0/applications?$filter=displayName%20eq%20%27%5BStorage%20Account%5D%20st1.file.core.windows.net%27&$select=id,appId'
  }
}

Describe 'Check result reporting' {
  It 'counts failures in the summary' {
    Clear-AvdCheckResult
    Add-AvdCheckResult 'A' 'one' 'Pass' 6>$null
    Add-AvdCheckResult 'A' 'two' 'Fail' -Remediation 'do x' 6>$null
    $summary = Write-AvdSummary 6>$null
    $summary.Failed | Should -Be 1
    $summary.Results.Count | Should -Be 2
  }
}

Describe 'Invoke-AvdGraph' {
  BeforeAll {
    # Stand-in so Pester can mock it without the Microsoft.Graph module installed.
    function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) }
  }
  AfterAll { Remove-Item function:global:Invoke-MgGraphRequest -ErrorAction SilentlyContinue }

  It 'follows nextLink and returns a flat list that @() does not nest' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest {
      if ($Uri -eq 'v1.0/things') { [pscustomobject]@{ value = @([pscustomobject]@{ n = 1 }, [pscustomobject]@{ n = 2 }); '@odata.nextLink' = 'page2' } }
      else { [pscustomobject]@{ value = @([pscustomobject]@{ n = 3 }) } }
    }
    $items = @(Invoke-AvdGraph -Uri 'v1.0/things')
    $items.Count | Should -Be 3
    ($items | ForEach-Object n) -join ',' | Should -Be '1,2,3'
    @(Invoke-AvdGraph -Uri 'v1.0/things' | Where-Object n -gt 1).Count | Should -Be 2
  }

  It 'returns nothing (not a nested empty array) for an empty collection' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { [pscustomobject]@{ value = @() } }
    @(Invoke-AvdGraph -Uri 'v1.0/empty').Count | Should -Be 0
  }

  It 'throws instead of looping when a page request fails' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { }
    { Invoke-AvdGraph -Uri 'v1.0/groups' } | Should -Throw
    Should -Invoke -ModuleName AvdLandingZone Invoke-MgGraphRequest -Times 1 -Exactly
  }
}

Describe 'Get-AvdProviderState' {
  BeforeAll {
    function global:Get-AzContext { [pscustomobject]@{ Subscription = [pscustomobject]@{ Id = 'sub' } } }
    function global:Get-AzResourceProvider { param($ProviderNamespace, $ErrorAction) }
  }
  AfterAll { 'Get-AzContext', 'Get-AzResourceProvider' | ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue } }

  It 'reads every namespace from one provider list call' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm {
      [pscustomobject]@{ value = @(
          [pscustomobject]@{ namespace = 'Microsoft.Compute'; registrationState = 'Registered' }
          [pscustomobject]@{ namespace = 'Microsoft.KeyVault'; registrationState = 'NotRegistered' }
        ) }
    }
    Mock -ModuleName AvdLandingZone Get-AzResourceProvider { }
    $s = Get-AvdProviderState -Namespace 'Microsoft.Compute', 'Microsoft.KeyVault'
    $s['Microsoft.Compute'] | Should -Be 'Registered'
    $s['Microsoft.KeyVault'] | Should -Be 'NotRegistered'
    Should -Invoke -ModuleName AvdLandingZone Invoke-AvdArm -Times 1 -Exactly
    Should -Invoke -ModuleName AvdLandingZone Get-AzResourceProvider -Times 0 -Exactly
  }

  It 'falls back to per-namespace lookups when the list call fails' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm { throw 'ARM GET failed (500)' }
    Mock -ModuleName AvdLandingZone Get-AzResourceProvider { [pscustomobject]@{ RegistrationState = 'Registering' } }
    (Get-AvdProviderState -Namespace 'Microsoft.Network')['Microsoft.Network'] | Should -Be 'Registering'
  }
}

Describe 'Test-AvdGraphToken' {
  BeforeAll { function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) } }
  AfterAll { Remove-Item function:global:Invoke-MgGraphRequest -ErrorAction SilentlyContinue }

  It 'is false when the sign-in cannot produce a token' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { throw 'DeviceCodeCredential authentication failed: Object reference not set to an instance of an object.' }
    Test-AvdGraphToken | Should -BeFalse
  }

  It 'is true on a permission error, which still proves a token was issued' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { throw 'Response status code does not indicate success: Forbidden (Forbidden).' }
    Test-AvdGraphToken | Should -BeTrue
  }

  It 'is true when the request succeeds' {
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest { [pscustomobject]@{ value = @([pscustomobject]@{ id = 'org' }) } }
    Test-AvdGraphToken | Should -BeTrue
  }
}

Describe 'Microsoft Graph scopes (decision 0016)' {
  It 'gives every purpose the same scope set, so one sign-in covers the session' {
    $all = Get-AvdGraphScope -Purpose SignIn
    $all.Count | Should -Be 8
    foreach ($p in 'Read', 'Fix', 'PreDeployFix', 'Cleanup') { (Get-AvdGraphScope -Purpose $p) -join ' ' | Should -Be ($all -join ' ') -Because $p }
  }
  It 'matches the scopes the operator app setup consents to' {
    $setup = Get-Content -Raw (Join-Path $PSScriptRoot '../../scripts/ops/Initialize-AvdGraphApp.ps1')
    $m = [regex]::Match($setup, '(?s)\$operatorScopes = @\((.*?)\)')
    $m.Success | Should -BeTrue
    $listed = @([regex]::Matches($m.Groups[1].Value, "'([^']+)'") | ForEach-Object { $_.Groups[1].Value })
    ($listed | Sort-Object) -join ' ' | Should -Be ((Get-AvdGraphScope | Sort-Object) -join ' ')
  }
  It 'covers every Graph call the scripts make' {
    # Each Graph path the scripts call, and the scope that allows it. A new call fails here until it is listed.
    $needs = [ordered]@{
      'v1\.0/(applications|servicePrincipals)\b'           = 'Application.ReadWrite.All'
      'collection (applications|servicePrincipals)'         = 'Application.ReadWrite.All'
      'directory/deletedItems'                              = 'Application.ReadWrite.All'
      'v1\.0/oauth2PermissionGrants|collection oauth2PermissionGrants' = 'DelegatedPermissionGrant.ReadWrite.All'
      'v1\.0/policies/'                                     = 'Policy.Read.All'
      'v1\.0/identity/conditionalAccess'                    = 'Policy.ReadWrite.ConditionalAccess'
      'v1\.0/groups|collection groups'                      = 'Group.ReadWrite.All'
      'v1\.0/(me|users|subscribedSkus|organization)\b'      = 'Directory.Read.All'
      'v1\.0/directoryRoles|collection directoryRoles'      = 'Directory.Read.All'
      'v1\.0/devices|collection devices'                    = 'Device.ReadWrite.All'
      'v1\.0/deviceManagement|collection deviceManagement/managedDevices' = 'DeviceManagementManagedDevices.ReadWrite.All'
    }
    $scopes = Get-AvdGraphScope
    $files = Get-ChildItem (Join-Path $PSScriptRoot '../../scripts/ops') -Filter *.ps*1 | Where-Object Name -ne 'Initialize-AvdGraphApp.ps1'
    $calls = foreach ($f in $files) {
      foreach ($line in (Get-Content $f.FullName)) {
        $u = [regex]::Match($line, 'Invoke-AvdGraph\b.*?-Uri\s+(\(Get-AvdGraphFilterUri -Collection (\S+)|\S+)')
        if (-not $u.Success) { continue }
        if ($u.Groups[2].Success) { 'collection ' + ($u.Groups[2].Value -replace '[''"]', '') } else { $u.Groups[1].Value }
      }
    }
    @($calls).Count | Should -BeGreaterThan 20
    foreach ($c in $calls) {
      $hit = @($needs.Keys | Where-Object { $c -match $_ }) | Select-Object -First 1
      $hit | Should -Not -BeNullOrEmpty -Because "$c needs a scope in the list above"
      $scopes | Should -Contain $needs[$hit] -Because $c
    }
  }
}

Describe 'Get-AvdGraphClientId' {
  AfterEach { $env:AVD_GRAPH_CLIENT_ID = $null }
  It 'is empty without a parameter or AVD_GRAPH_CLIENT_ID (the default app)' { $env:AVD_GRAPH_CLIENT_ID = $null; Get-AvdGraphClientId | Should -BeNullOrEmpty }
  It 'reads AVD_GRAPH_CLIENT_ID, and the parameter wins' {
    $env:AVD_GRAPH_CLIENT_ID = ' 11111111-1111-1111-1111-111111111111 '
    Get-AvdGraphClientId | Should -Be '11111111-1111-1111-1111-111111111111'
    Get-AvdGraphClientId -ClientId '22222222-2222-2222-2222-222222222222' | Should -Be '22222222-2222-2222-2222-222222222222'
  }
  It 'rejects a value that is not a GUID, naming how to clear it' {
    $env:AVD_GRAPH_CLIENT_ID = 'avd-opsbot'
    { Get-AvdGraphClientId } | Should -Throw '*Remove-Item Env:AVD_GRAPH_CLIENT_ID*'
  }
}

Describe 'Test-AvdHostPoolRegion' {
  BeforeEach {
    Clear-AvdCheckResult
    # Shape of GET /subscriptions/{id}/providers/Microsoft.DesktopVirtualization
    Mock -ModuleName AvdLandingZone Invoke-AvdArm {
      [pscustomobject]@{ resourceTypes = @(
          [pscustomobject]@{ resourceType = 'workspaces'; locations = @('Brazil South') }
          [pscustomobject]@{ resourceType = 'hostpools'; locations = @('North Central US', 'West US 2') }
        ) }
    }
  }

  It 'passes for a host pool region given by its ARM name' {
    Test-AvdHostPoolRegion -Location 'westus2' -SubscriptionId 'sub'
    (Get-AvdCheckResult).Status | Should -Be 'Pass'
  }

  It 'warns instead of failing when the provider cannot be read' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm { throw 'ARM GET failed (403)' }
    Test-AvdHostPoolRegion -Location 'westus2' -SubscriptionId 'sub'
    (Get-AvdCheckResult).Status | Should -Be 'Warn'
  }

  It 'fails for a region without host pools and lists the ones that have them' {
    Test-AvdHostPoolRegion -Location 'brazilsouth' -SubscriptionId 'sub'
    $r = Get-AvdCheckResult
    $r.Status | Should -Be 'Fail'
    $r.Detail | Should -BeLike '*northcentralus, westus2*'
  }
}

Describe 'Test-AvdResourceProvider -Fix' {
  BeforeAll {
    # Stand-ins so Pester can mock them without the Az modules installed.
    function global:Get-AzProviderFeature { param($ProviderNamespace, $FeatureName, $ErrorAction) }
    function global:Register-AzProviderFeature { param($ProviderNamespace, $FeatureName) }
  }
  AfterAll {
    'Get-AzProviderFeature', 'Register-AzProviderFeature' |
      ForEach-Object { Remove-Item "function:global:$_" -ErrorAction SilentlyContinue }
  }
  BeforeEach {
    Clear-AvdCheckResult
    $global:AvdTestPolls = 0
    Mock -ModuleName AvdLandingZone Start-Sleep { $global:AvdTestPolls++ }
    Mock -ModuleName AvdLandingZone Register-AvdResourceProvider { }
    Mock -ModuleName AvdLandingZone Register-AzProviderFeature { }
    # Everything turns Registered after the first poll.
    Mock -ModuleName AvdLandingZone Get-AvdProviderState {
      $s = [ordered]@{}; foreach ($ns in $Namespace) { $s[$ns] = $(if ($global:AvdTestPolls) { 'Registered' } else { 'NotRegistered' }) }; $s
    }
    Mock -ModuleName AvdLandingZone Get-AzProviderFeature { [pscustomobject]@{ RegistrationState = $(if ($global:AvdTestPolls) { 'Registered' } else { 'NotRegistered' }) } }
  }
  AfterEach { Remove-Variable AvdTestPolls -Scope Global -ErrorAction SilentlyContinue }

  It 'waits for the registrations, reports Fixed and re-registers Microsoft.Compute' {
    Test-AvdResourceProvider -Namespace 'Microsoft.KeyVault' -Fix 6>$null
    $r = Get-AvdCheckResult
    ($r | Where-Object Check -like 'Provider*').Status | Should -Be 'Fixed'
    ($r | Where-Object Check -like 'Feature*').Status | Should -Be 'Fixed'
    Should -Invoke -ModuleName AvdLandingZone Register-AvdResourceProvider -ParameterFilter { $Namespace -eq 'Microsoft.Compute' } -Times 1 -Exactly
  }

  It 'warns and does not re-register Compute when the feature is still registering at the timeout' {
    Mock -ModuleName AvdLandingZone Get-AzProviderFeature { [pscustomobject]@{ RegistrationState = 'Registering' } }
    Test-AvdResourceProvider -Namespace @() -Fix -WaitMinutes 0 6>$null
    $r = Get-AvdCheckResult
    ($r | Where-Object Check -like 'Feature*').Status | Should -Be 'Warn'
    Should -Invoke -ModuleName AvdLandingZone Register-AvdResourceProvider -Times 0 -Exactly
  }

  It 'only reports in check mode' {
    Test-AvdResourceProvider -Namespace 'Microsoft.KeyVault' 6>$null
    $r = Get-AvdCheckResult
    @($r | Where-Object Status -eq 'Fail').Count | Should -Be 2
    Should -Invoke -ModuleName AvdLandingZone Register-AvdResourceProvider -Times 0 -Exactly
    Should -Invoke -ModuleName AvdLandingZone Start-Sleep -Times 0 -Exactly
  }
}

Describe 'Add-AvdCallerToGroup' {
  BeforeAll { function global:Invoke-MgGraphRequest { param($Method, $Uri, $Body, $ContentType, $OutputType) } }
  AfterAll { Remove-Item function:global:Invoke-MgGraphRequest -ErrorAction SilentlyContinue }

  It 'adds the signed-in user only to groups they are not already in' {
    Clear-AvdCheckResult
    Mock -ModuleName AvdLandingZone Invoke-MgGraphRequest {
      if ($Method -eq 'POST') { return }
      if ($Uri.StartsWith('v1.0/me?')) { return [pscustomobject]@{ id = 'me1'; userPrincipalName = 'alex@contoso.com' } }
      [pscustomobject]@{ value = @([pscustomobject]@{ id = 'g-admins' }) }
    }
    Add-AvdCallerToGroup -Group @(
      @('AVD Users', [pscustomobject]@{ id = 'g-users'; displayName = 'AVD Users' }),
      @('AVD Admins', [pscustomobject]@{ id = 'g-admins'; displayName = 'AVD Admins' })
    )
    Should -Invoke -ModuleName AvdLandingZone Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' } -Times 1 -Exactly
    Should -Invoke -ModuleName AvdLandingZone Invoke-MgGraphRequest -ParameterFilter { $Method -eq 'POST' -and $Uri -eq 'v1.0/groups/g-users/members/$ref' } -Times 1 -Exactly
    (Get-AvdCheckResult).Status -join ',' | Should -Be 'Fixed,Pass'
  }
}

Describe 'Get-AvdPrivateEndpointDnsZoneId' {
  It 'searches the whole subscription and returns the zone of the endpoint that fronts the target' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm {
      if ($Path -like '*/privateDnsZoneGroups*') {
        return [pscustomobject]@{ value = @([pscustomobject]@{ properties = [pscustomobject]@{ privateDnsZoneConfigs = @(
                  [pscustomobject]@{ properties = [pscustomobject]@{ privateDnsZoneId = '/zones/privatelink.file.core.windows.net' } }) } }) }
      }
      [pscustomobject]@{ value = @([pscustomobject]@{
            id         = '/subscriptions/sub/resourceGroups/rg-avdlz-dev-storage/providers/Microsoft.Network/privateEndpoints/pe-st'
            properties = [pscustomobject]@{ privateLinkServiceConnections = @([pscustomobject]@{ properties = [pscustomobject]@{ privateLinkServiceId = '/subscriptions/sub/resourceGroups/rg-avdlz-dev-storage/providers/Microsoft.Storage/storageAccounts/st1' } }) }
          }) }
    }
    $r = Get-AvdPrivateEndpointDnsZoneId -SubscriptionId 'sub' -TargetResourceId '/subscriptions/sub/resourceGroups/rg-avdlz-dev-storage/providers/Microsoft.Storage/storageAccounts/st1'
    $r.DnsZoneId | Should -Be '/zones/privatelink.file.core.windows.net'
    Should -Invoke -ModuleName AvdLandingZone Invoke-AvdArm -ParameterFilter { $Path -like '/subscriptions/sub/providers/Microsoft.Network/privateEndpoints?*' } -Times 1 -Exactly
  }
}

Describe 'Profile share ACL error reporting' {
  It 'names the step, HTTP status, storage error code, message and resolved IP' {
    $r = [pscustomobject]@{ status = 'Error'; step = 'get share permission'; httpStatus = 400; errorCode = 'InvalidHeaderValue'; detail = 'Bad header.'; error = '(400) Bad Request.'; resolvedIp = '10.20.1.4' }
    $text = Format-AvdShareAclError $r
    $text | Should -BeLike "*get share permission*HTTP 400*InvalidHeaderValue*Bad header.*10.20.1.4*"
    Get-AvdShareAclRemediation $r | Should -BeLike '*Azure Files API rejected*'
  }

  It 'points at DNS when the storage account resolves to a public IP' {
    Get-AvdShareAclRemediation ([pscustomobject]@{ status = 'Error'; httpStatus = 403; error = 'x'; resolvedIp = '20.60.1.5' }) | Should -BeLike '*private IP*'
  }
}

Describe 'Get-AvdArmList' {
  It 'follows nextLink as a path and returns a flat list' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm {
      if ($Path -notmatch 'skipToken') { [pscustomobject]@{ value = @([pscustomobject]@{ n = 1 }, [pscustomobject]@{ n = 2 }); nextLink = 'https://management.azure.com/subscriptions/s/things?api-version=1&$skipToken=2' } }
      else { [pscustomobject]@{ value = @([pscustomobject]@{ n = 3 }) } }
    }
    $items = @(Get-AvdArmList -Path '/subscriptions/s/things?api-version=1')
    ($items | ForEach-Object n) -join ',' | Should -Be '1,2,3'
    Should -Invoke -ModuleName AvdLandingZone Invoke-AvdArm -ParameterFilter { $Path -eq '/subscriptions/s/things?api-version=1&$skipToken=2' } -Times 1 -Exactly
  }

  It 'stops at MaxPages when nextLink never ends' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm { [pscustomobject]@{ value = @([pscustomobject]@{ n = 1 }); nextLink = 'https://management.azure.com/again' } }
    @(Get-AvdArmList -Path '/x' -MaxPages 3).Count | Should -Be 3
    Should -Invoke -ModuleName AvdLandingZone Invoke-AvdArm -Times 3 -Exactly
  }

  It 'stops on an empty page and passes an error through' {
    Mock -ModuleName AvdLandingZone Invoke-AvdArm { [pscustomobject]@{ value = @(); nextLink = 'https://management.azure.com/again' } }
    @(Get-AvdArmList -Path '/x').Count | Should -Be 0
    Should -Invoke -ModuleName AvdLandingZone Invoke-AvdArm -Times 1 -Exactly
    Mock -ModuleName AvdLandingZone Invoke-AvdArm { throw 'ARM GET /x failed (403)' }
    { Get-AvdArmList -Path '/x' } | Should -Throw '*403*'
  }
}

Describe 'Well-Architected findings' {
  BeforeEach { Clear-AvdCheckResult }

  It 'marks a dev trade-off as expected, and the same finding in prod as a plain warning' {
    Add-AvdWafResult -Pillar Reliability -Key host-count -Check 'Two hosts' -Ok $false -Detail '1 session host(s)' -Environment dev -TradeOff
    Add-AvdWafResult -Pillar Reliability -Key host-count -Check 'Two hosts' -Ok $false -Detail '1 session host(s)' -Environment prod -TradeOff
    $r = Get-AvdCheckResult
    $r[0].Status | Should -Be 'Warn'
    $r[0].Id | Should -Be 'waf-host-count'
    $r[0].Data.accepted | Should -BeTrue
    $r[0].Detail | Should -Be '1 session host(s). Expected in dev (parameters/dev.bicepparam); change it before production.'
    $r[1].Data.accepted | Should -BeFalse
    $r[1].Detail | Should -Be '1 session host(s)'
  }

  It 'never fails a run: a finding is Pass or Warn' {
    Add-AvdWafResult -Pillar Security -Key x -Check 'Hardened' -Ok $true
    Add-AvdWafResult -Pillar Security -Key y -Check 'Hardened' -Ok $false
    $r = Get-AvdCheckResult
    ($r | ForEach-Object Status) -join ',' | Should -Be 'Pass,Warn'
    $r[1].Data.pillar | Should -Be 'Security'
  }

  It 'reads the pillar from a PSRule record tag' {
    Get-AvdPSRulePillar ([pscustomobject]@{ Tag = @{ 'Azure.WAF/pillar' = 'Cost Optimization' } }) | Should -Be 'Cost Optimization'
    Get-AvdPSRulePillar ([pscustomobject]@{ Tag = $null }) | Should -Be ''
  }
}

Describe 'Get-AvdRetailPrice' {
  It 'follows NextPageLink and stops at MaxPages' {
    Mock -ModuleName AvdLandingZone Invoke-RestMethod { [pscustomobject]@{ Items = @([pscustomobject]@{ meterName = 'm' }); NextPageLink = 'https://prices.azure.com/api/retail/prices?next' } }
    @(Get-AvdRetailPrice -Filter "serviceName eq 'X'" -MaxPages 3).Count | Should -Be 3
    Should -Invoke -ModuleName AvdLandingZone Invoke-RestMethod -Times 3 -Exactly
  }
  It 'stops on an empty page and passes an error through' {
    Mock -ModuleName AvdLandingZone Invoke-RestMethod { [pscustomobject]@{ Items = @(); NextPageLink = 'x' } }
    @(Get-AvdRetailPrice -Filter "serviceName eq 'X'").Count | Should -Be 0
    Mock -ModuleName AvdLandingZone Invoke-RestMethod { throw '503' }
    { Get-AvdRetailPrice -Filter "serviceName eq 'X'" } | Should -Throw '*503*'
  }
  It 'asks for the currency and escapes the filter' {
    Mock -ModuleName AvdLandingZone Invoke-RestMethod { [pscustomobject]@{ Items = @() } }
    Get-AvdRetailPrice -Filter "armRegionName eq 'westus2'" -Currency EUR | Out-Null
    # $Uri reaches the mock as a System.Uri, whose ToString() un-escapes: compare the string as sent.
    Should -Invoke -ModuleName AvdLandingZone Invoke-RestMethod -ParameterFilter { "$($Uri.OriginalString)$(if ($Uri -is [string]) { $Uri })" -like "*currencyCode='EUR'*" -and "$($Uri.OriginalString)$(if ($Uri -is [string]) { $Uri })" -like '*armRegionName%20eq%20%27westus2%27*' } -Times 1 -Exactly
  }
}

Describe 'Get-AvdCostEstimate' {
  BeforeAll {
    $script:plan = @{ location = 'westus2'; sessionHostCount = 2; sessionHostVmSize = 'Standard_D4as_v5'; profileShareQuotaGiB = 100; profileStorageSku = 'Premium_LRS'; connectivityMode = 'HubPeered'; enableAvdPrivateLink = $false }
  }
  It 'leaves a line unpriced when two different meters match, instead of picking one' {
    Mock -ModuleName AvdLandingZone Get-AvdRetailPrice {
      if ($Filter -like "*Virtual Machines*") { [pscustomobject]@{ productName = 'Virtual Machines Dasv5 Series'; skuName = 'D4as v5'; meterName = 'D4as v5'; unitOfMeasure = '1 Hour'; retailPrice = 0.2 } }
      elseif ($Filter -like "*Premium Files*") {
        [pscustomobject]@{ productName = 'Premium Files'; skuName = 'Premium LRS'; meterName = 'LRS Provisioned'; unitOfMeasure = '1 GiB/Month'; retailPrice = 0.16 }
        [pscustomobject]@{ productName = 'Premium Files'; skuName = 'Premium LRS'; meterName = 'LRS Provisioned v2'; unitOfMeasure = '1 GiB/Month'; retailPrice = 0.1 }
      }
    }
    $e = Get-AvdCostEstimate -Plan $plan -ActiveHoursPerWeek 40
    $compute = $e.lines | Where-Object key -eq 'compute'
    $compute.quantity | Should -Be ([math]::Round(2 * 40 * 52 / 12, 1))
    $compute.monthly | Should -Be ([math]::Round(0.2 * $compute.quantity, 2))
    ($e.unpriced | ForEach-Object key) | Should -Contain 'profiles'
    (($e.unpriced | Where-Object key -eq 'profiles').seen -join ' ') | Should -Match 'v2'
    ($e.lines + $e.unpriced | ForEach-Object key) | Should -Not -Contain 'natgateway'   # hub-peered: no NAT Gateway
    ($e.lines | Where-Object key -eq 'privateendpoints') | Should -BeNullOrEmpty       # not priced by the mock
    ($e.unpriced | ForEach-Object { $_.item }) | Should -Contain 'Private endpoints (2)'  # no AVD Private Link: storage + Key Vault
  }
}

Describe 'Get-AvdUserConnectionOutcome (decision 0014)' {
  It 'fails closed: nothing is "none", never verified' {
    (Get-AvdUserConnectionOutcome -Row @()).Status | Should -Be 'none'
    (Get-AvdUserConnectionOutcome -Row @($null)).Status | Should -Be 'none'
  }
  It 'reads the dynamic columns the query API returns as JSON strings' {
    $row = [pscustomobject]@{ CorrelationId = 'c1'; StartedAt = 't0'; ConnectedAt = $null; Errors = '[{"code":"X","message":"m","source":"s","serviceError":false}]'; Checkpoints = '["a","b"]' }
    $o = Get-AvdUserConnectionOutcome -Row @($row)
    $o.Status | Should -Be 'failed'
    $o.Connections[0].errors[0].code | Should -Be 'X'
    $o.Connections[0].checkpoints | Should -Be @('a', 'b')
  }
  It 'a connection with no errors and no Connected time is in progress; Connected anywhere is verified' {
    $started = [pscustomobject]@{ CorrelationId = 'c1'; StartedAt = 't0' }
    (Get-AvdUserConnectionOutcome -Row @($started)).Status | Should -Be 'inprogress'
    $ok = [pscustomobject]@{ CorrelationId = 'c2'; StartedAt = 't0'; ConnectedAt = 't1'; ConnectionSetupSeconds = 3.14159; Errors = '[]' }
    $o = Get-AvdUserConnectionOutcome -Row @($started, $ok)
    $o.Status | Should -Be 'verified'
    $o.Connected[0].connectionSetupSeconds | Should -Be 3.1
  }
}

Describe 'Get-AvdRunPosition' {
  # Fixtures omit empty properties the way ARM does (lesson 0021).
  BeforeAll {
    $now = [datetime]'2026-10-20T17:30:00Z'
    $all = @{ Network = $true; Management = $true; Storage = $true; ControlPlane = $true; Hosts = $true; Demo = $false }
    $none = @{ Network = $false; Management = $false; Storage = $false; ControlPlane = $false; Hosts = $false; Demo = $false }
    $dep = { param($name, $state, $time) [pscustomobject]@{ name = $name; properties = [pscustomobject]@{ provisioningState = $state; timestamp = $time } } }
  }

  It 'says start from the beginning when there is nothing' {
    $p = Get-AvdRunPosition -Environment dev -RgExists $none -Now $now
    $p.Status | Should -Be 'ready'
    $p.NextStage | Should -Be 'predeploy'
  }

  It 'waits for a running deployment, even when an older one succeeded' {
    $d = @((& $dep 'avdlz-dev-20261019-100000' 'Succeeded' '2026-10-19T10:40:00Z'), (& $dep 'avdlz-dev-20261020-171800' 'Running' '2026-10-20T17:18:00Z'))
    $p = Get-AvdRunPosition -Environment dev -Deployment $d -RgExists $none -Now $now
    $p.LastStatus | Should -Be 'running'
    $p.NextStage | Should -Be 'deploy'
    $p.DeploymentName | Should -Be 'avdlz-dev-20261020-171800'
    $p.Basis | Should -Match '12 minutes ago'
  }

  It 'reports a failed deployment' {
    $p = Get-AvdRunPosition -Environment dev -Deployment @(& $dep 'avdlz-dev-20261020-171800' 'Failed' '2026-10-20T17:25:00Z') -RgExists $all -Now $now
    $p.LastStatus | Should -Be 'failed'
    $p.NextStage | Should -Be 'deploy'
  }

  It 'goes to the post-deployment setup after a successful deployment' {
    $p = Get-AvdRunPosition -Environment dev -Deployment @(& $dep 'avdlz-dev-20261020-171800' 'Succeeded' '2026-10-20T17:25:00Z') -RgExists $all -Now $now
    $p.NextStage | Should -Be 'postdeploy'
  }

  It 'goes to the access check once the demo is deployed' {
    $rg = $all.Clone(); $rg.Demo = $true
    $p = Get-AvdRunPosition -Environment dev -Deployment @(& $dep 'avdlz-dev-20261020-171800' 'Succeeded' '2026-10-20T17:25:00Z') -RgExists $rg `
      -DemoDeployment (& $dep 'avdlz-demo-avdlz-dev' 'Succeeded' '2026-10-20T17:29:00Z') -Now $now
    $p.LastStage | Should -Be 'demo'
    $p.NextStage | Should -Be 'verify'
  }

  It 'starts again after a cleanup removed the landing zone' {
    $p = Get-AvdRunPosition -Environment dev -Deployment @(& $dep 'avdlz-dev-20261020-171800' 'Succeeded' '2026-10-20T17:25:00Z') -RgExists $none -Now $now
    $p.LastStage | Should -Be 'cleanup'
    $p.NextStage | Should -Be 'predeploy'
  }

  It 'is unknown, never a guess, with resource groups but no deployment record' {
    $p = Get-AvdRunPosition -Environment dev -RgExists $all -Now $now
    $p.Status | Should -Be 'unknown'
    $p.NextStage | Should -BeNullOrEmpty
  }

  It 'ignores the demo record and other environments when picking the deployment' {
    $d = @((& $dep 'avdlz-demo-avdlz-dev' 'Running' '2026-10-20T17:29:00Z'), (& $dep 'avdlz-prod-20261020-172000' 'Running' '2026-10-20T17:20:00Z'),
      (& $dep 'avdlz-dev-20261020-171800' 'Succeeded' '2026-10-20T17:25:00Z'))
    $p = Get-AvdRunPosition -Environment dev -Deployment $d -RgExists $all -Now $now
    $p.DeploymentName | Should -Be 'avdlz-dev-20261020-171800'
    $p.NextStage | Should -Be 'postdeploy'
  }
}

Describe 'Run journal' {
  BeforeAll {
    $runId = 'run-20261020-1652-k3p9'
  }
  AfterEach {
    Remove-Item Env:AVDLZ_RECORD, Env:AVDLZ_RUN_ID -ErrorAction SilentlyContinue
  }

  It 'is off unless AVDLZ_RECORD is set' {
    (Get-AvdJournalSetting -HomePath '/home/op').Enabled | Should -BeFalse
    (Get-AvdJournalSetting -Record off -RunId $runId -HomePath '/home/op').Reason | Should -Be 'off'
  }

  It 'refuses an unknown mode or a missing run ID instead of guessing' {
    (Get-AvdJournalSetting -Record yes -RunId $runId -HomePath '/home/op').Reason | Should -Match 'on, azure or off'
    $s = Get-AvdJournalSetting -Record on -RunId 'my run' -HomePath '/home/op'
    $s.Enabled | Should -BeFalse
    $s.Reason | Should -Match 'AVDLZ_RUN_ID'
  }

  It 'writes to clouddrive when it is mounted, so the journal survives a reset' {
    $s = Get-AvdJournalSetting -Record on -RunId $runId -HomePath '/home/op' -CloudDriveExists $true
    $s.Enabled | Should -BeTrue
    $s.Durable | Should -BeTrue
    $s.Path | Should -Be (Join-Path (Join-Path (Join-Path (Join-Path '/home/op' 'clouddrive') 'avdlz-runs') $runId) 'journal.jsonl')
  }

  It 'writes to the home folder in an ephemeral session' {
    $s = Get-AvdJournalSetting -Record azure -RunId $runId -HomePath '/home/op'
    $s.Durable | Should -BeFalse
    $s.Folder | Should -Be (Join-Path (Join-Path '/home/op' 'avdlz-runs') $runId)
  }

  It 'never keeps a secret parameter' {
    $p = Get-AvdJournalParam @{
      NamePrefix = 'avdlz'; Fix = [switch]$true; AdminPassword = 'Placeholder-only-1!'; KeyVaultName = 'kv-x'
      Secure = (ConvertTo-SecureString 'Placeholder-only-1!' -AsPlainText -Force); Regions = @('northcentralus', 'eastus2')
    }
    $p.NamePrefix | Should -Be 'avdlz'
    $p.Fix | Should -BeTrue
    $p.AdminPassword | Should -Be '<set>'
    $p.KeyVaultName | Should -Be '<set>'
    $p.Secure | Should -Be '<set>'
    $p.Regions | Should -Be @('northcentralus', 'eastus2')
    ($p | ConvertTo-Json -Compress) | Should -Not -Match 'Placeholder'
  }

  It 'builds a line with the version, event, run ID and UTC time first' {
    $e = Get-AvdJournalEvent -Name check -RunId $runId -Field ([ordered]@{ id = 'x'; status = 'Pass' }) -Now ([datetime]'2026-10-20T17:30:00Z')
    @($e.Keys)[0..3] | Should -Be @('v', 'event', 'runId', 'ts')
    $e.ts | Should -Be '2026-10-20T17:30:00.000Z'
    $e.status | Should -Be 'Pass'
  }

  It 'appends one JSON object per line when recording is on' {
    $env:AVDLZ_RECORD = 'on'; $env:AVDLZ_RUN_ID = $runId
    Write-AvdJournalEvent 'operator.note' ([ordered]@{ step = 'test'; text = 'set the share quota by hand' }) -HomePath $TestDrive
    Write-AvdJournalEvent 'check' ([ordered]@{ step = 'test'; id = 'a'; status = 'Warn'; area = 'Run'; check = 'c' }) -HomePath $TestDrive
    $lines = @(Get-Content (Join-Path (Join-Path (Join-Path $TestDrive 'avdlz-runs') $runId) 'journal.jsonl'))
    $lines.Count | Should -Be 2
    ($lines[0] | ConvertFrom-Json).text | Should -Be 'set the share quota by hand'
    ($lines[1] | ConvertFrom-Json).event | Should -Be 'check'
    # The family's run record contract (avd-second-brain C17), vendored in contracts/.
    $schema = Join-Path $PSScriptRoot '../../contracts/schemas/run-journal.schema.json'
    foreach ($l in $lines) { Test-Json -Json $l -SchemaFile $schema | Should -BeTrue }
  }

  It 'writes nothing when recording is off' {
    $home_ = Join-Path $TestDrive 'off'
    Write-AvdJournalEvent 'operator.note' @{ text = 'x' } -HomePath $home_
    $home_ | Should -Not -Exist
  }

  It 'journals every check result when recording is on' {
    $env:AVDLZ_RECORD = 'on'; $env:AVDLZ_RUN_ID = $runId
    Mock Write-AvdJournalEvent -ModuleName AvdLandingZone
    Add-AvdCheckResult 'Run' 'A check' 'Warn' -Id 'a-check' -Data @{ n = 1 } 6>$null
    Should -Invoke Write-AvdJournalEvent -ModuleName AvdLandingZone -Times 1 -ParameterFilter { $Name -eq 'check' -and $Field.id -eq 'a-check' -and $Field.status -eq 'Warn' }
    Clear-AvdCheckResult
  }
}

Describe 'Get-AvdLocationPolicyVerdict (recovery spec section 4.1)' {
  BeforeAll {
    $def = '/providers/Microsoft.Authorization/policyDefinitions/'
    function New-Assignment($Name, $Definition, $Allowed, $Mode) {
      $p = [pscustomobject]@{ policyDefinitionId = "$def$Definition" }
      if ($Allowed) { $p | Add-Member parameters ([pscustomobject]@{ listOfAllowedLocations = [pscustomobject]@{ value = @($Allowed) } }) }
      if ($Mode) { $p | Add-Member enforcementMode $Mode }
      [pscustomobject]@{ name = $Name; properties = $p }
    }
  }
  It 'returns the allowed-locations assignments that leave the region out, own and foreign' {
    $a = @(
      New-Assignment 'avdlz-allowed-locations' 'e56962a6-4747-49cd-b67b-bf8b01975c4c' @('northcentralus')
      New-Assignment 'corp-rg-locations' 'e765b5de-1225-4ba3-bd56-1ac6695af988' @('NorthCentralUS', 'SouthCentralUS')
      New-Assignment 'corp-audit' 'e765b5de-1225-4ba3-bd56-1ac6695af988' @('northcentralus') 'DoNotEnforce'
      New-Assignment 'other-policy' '0a914e76-4921-4c19-b460-a2d36003525a' @('northcentralus')
      [pscustomobject]@{ name = 'no-properties' }   # ARM leaves out what an assignment doesn't have
    )
    $v = @(Get-AvdLocationPolicyVerdict -Assignment $a -Location 'southcentralus')
    $v.Name | Should -Be @('avdlz-allowed-locations', 'corp-audit')
    $v[0].Managed | Should -BeTrue
    $v[0].Enforced | Should -BeTrue
    $v[1].Managed | Should -BeFalse
    $v[1].Enforced | Should -BeFalse
  }
  It 'returns nothing for no assignments, or an assignment without a list' {
    @(Get-AvdLocationPolicyVerdict -Assignment @() -Location 'eastus2').Count | Should -Be 0
    @(Get-AvdLocationPolicyVerdict -Assignment @(New-Assignment 'x' 'e56962a6-4747-49cd-b67b-bf8b01975c4c') -Location 'eastus2').Count | Should -Be 0
  }
}

Describe 'Get-AvdProfileBackupVerdict' {
  BeforeAll {
    $now = [datetime]'2026-10-20T12:00:00Z'
    $sa = [pscustomobject]@{ properties = [pscustomobject]@{ allowSharedKeyAccess = $false; publicNetworkAccess = 'Disabled' } }
    function New-ProtectedItem($Props) { [pscustomobject]@{ name = 'AzureFileShare;profiles'; properties = [pscustomobject]$Props } }
  }
  It 'passes a protected, healthy item backed up within a day' {
    $v = Get-AvdProfileBackupVerdict -StorageAccount $sa -ProtectedItem @(New-ProtectedItem @{ friendlyName = 'profiles'; protectionState = 'Protected'; healthStatus = 'Passed'; lastBackupStatus = 'Healthy'; lastBackupTime = $now.AddHours(-5) }) -Now $now
    ($v | Where-Object Id -eq 'profile-backup-access').Status | Should -Be 'Pass'
    ($v | Where-Object Id -eq 'profile-backup').Status | Should -Be 'Pass'
  }
  It 'warns on a failed, stale backup and names the key-based error when key access is off' {
    $b = Get-AvdProfileBackupVerdict -StorageAccount $sa -ProtectedItem @(New-ProtectedItem @{ friendlyName = 'profiles'; protectionState = 'Protected'; lastBackupStatus = 'Unhealthy'; lastBackupTime = $now.AddHours(-50) }) -Now $now | Where-Object Id -eq 'profile-backup'
    $b.Status | Should -Be 'Warn'
    $b.Detail | Should -Be 'profiles last backup Unhealthy; profiles last backup 50 hours ago'
    $b.Remediation | Should -Match 'UserErrorStorageKeyBasedAuthenticationNotPermitted'
  }
  It 'warns when nothing is protected, or nothing has run yet' {
    (Get-AvdProfileBackupVerdict -StorageAccount $sa -ProtectedItem @() -Now $now | Where-Object Id -eq 'profile-backup').Status | Should -Be 'Warn'
    (Get-AvdProfileBackupVerdict -ProtectedItem @(New-ProtectedItem @{ protectionState = 'IRPending' }) -Now $now).Detail | Should -Be 'AzureFileShare;profiles protection state IRPending; AzureFileShare;profiles has no backup yet'
  }
  It 'warns when Azure Backup has neither key access nor a private-only account' {
    $open = [pscustomobject]@{ properties = [pscustomobject]@{ allowSharedKeyAccess = $false; publicNetworkAccess = 'Enabled' } }
    (Get-AvdProfileBackupVerdict -StorageAccount $open -ProtectedItem @() -Now $now | Where-Object Id -eq 'profile-backup-access').Status | Should -Be 'Warn'
  }
}

Describe 'Deployment portal hosting (decision 0017)' {
  BeforeAll {
    $pa = { param($id, [string[]] $locations, $mode = 'Default') [pscustomobject]@{ properties = [pscustomobject]@{ policyDefinitionId = "/providers/Microsoft.Authorization/policyDefinitions/$id"; enforcementMode = $mode; parameters = [pscustomobject]@{ listOfAllowedLocations = [pscustomobject]@{ value = $locations } } } } }
    $res = 'e56962a6-4747-49cd-b67b-bf8b01975c4c'; $rgs = 'e765b5de-1225-4ba3-bd56-1ac6695af988'
  }
  It 'puts Static Web Apps in the landing zone region when it is offered there, else the first one the policy allows' {
    (Get-AvdPortalHostRegion -Hosting StaticWebApp -Location eastus2).ResourceLocation | Should -Be 'eastus2'
    $r = Get-AvdPortalHostRegion -Hosting StaticWebApp -Location northcentralus -Assignments @((& $pa $res @('northcentralus', 'westus2')))
    $r.ResourceLocation | Should -Be 'westus2'
    $r.Allowed | Should -BeTrue
    (Get-AvdPortalHostRegion -Hosting StaticWebApp -Location northcentralus).ResourceLocation | Should -Be 'centralus'
  }
  It 'blocks Static Web Apps when the allowed list has none of its regions, with the storage way out' {
    $r = Get-AvdPortalHostRegion -Hosting StaticWebApp -Location northcentralus -Assignments @((& $pa $res @('northcentralus')))
    $r.Allowed | Should -BeFalse
    $r.Remediation | Should -Match '-Hosting Storage'
  }
  It 'ignores an assignment that is not enforced, and intersects two that are' {
    (Get-AvdPortalHostRegion -Hosting StaticWebApp -Location northcentralus -Assignments @((& $pa $res @('northcentralus') 'DoNotEnforce'))).Allowed | Should -BeTrue
    $r = Get-AvdPortalHostRegion -Hosting Storage -Location eastus2 -Assignments @((& $pa $res @('eastus2', 'westus2')), (& $pa $res @('westus2')))
    $r.Allowed | Should -BeFalse
    $r.Detail | Should -Match 'allowed: westus2'
  }
  It 'checks the resource group region against the resource group policy' {
    $r = Get-AvdPortalHostRegion -Hosting Storage -Location eastus2 -Assignments @((& $pa $rgs @('northcentralus')))
    $r.Allowed | Should -BeFalse
    $r.Remediation | Should -Match 'northcentralus'
  }
  It 'refuses a region Static Web Apps does not offer' {
    (Get-AvdPortalHostRegion -Hosting StaticWebApp -Location eastus2 -StaticWebAppLocation northcentralus).Allowed | Should -BeFalse
  }
  It 'writes portal-config.js as one JSON object, and refuses a repo URL or ref that could carry a command' {
    $js = Get-AvdPortalConfigScript -RepoUrl 'https://github.com/contoso/avd-landing-zone/' -Ref 'v1.2.0' -PortalUrl 'https://x.azurestaticapps.net/portal/' -Hosting StaticWebApp
    $js | Should -Match 'window\.AVDLZ_PORTAL_CONFIG = \{"repoUrl":"https://github.com/contoso/avd-landing-zone","ref":"v1.2.0","portalUrl":"https://x.azurestaticapps.net/portal/","hosting":"StaticWebApp"\};'
    foreach ($bad in 'https://github.com/x/y; iex', 'https://evil.example/x/y', 'https://github.com/x/../y', 'git@github.com:x/y') {
      { Get-AvdPortalConfigScript -RepoUrl $bad -Ref v1 -PortalUrl 'https://x/' -Hosting Storage } | Should -Throw -Because $bad
    }
    foreach ($bad in '--upload-pack=x', 'v1;rm', 'a..b', 'v1 ', 'refs/heads/', 'x.lock') {
      { Get-AvdPortalConfigScript -RepoUrl 'https://github.com/x/y' -Ref $bad -PortalUrl 'https://x/' -Hosting Storage } | Should -Throw -Because $bad
    }
  }
  It "never uses the 'authenticated' role alone, and always sends the security headers" {
    $open = Get-AvdStaticWebAppConfig | ConvertFrom-Json
    @($open.routes | Where-Object { $_ }).Count | Should -Be 0
    $open.globalHeaders.'X-Frame-Options' | Should -Be 'DENY'
    $locked = Get-AvdStaticWebAppConfig -RequireSignIn | ConvertFrom-Json
    @($locked.routes | Where-Object { @($_.allowedRoles) -contains 'authenticated' }).Count | Should -Be 0
    ($locked.routes | Where-Object route -eq '/*').allowedRoles | Should -Be @('operator')
  }
  It 'gives a storage static website the content types the browser needs' {
    Get-AvdPortalContentType 'portal/index.html' | Should -Be 'text/html; charset=utf-8'
    Get-AvdPortalContentType 'assets/fonts/x.woff2' | Should -Be 'font/woff2'
    Get-AvdPortalContentType 'assets/brand/mark.SVG' | Should -Be 'image/svg+xml'
    Get-AvdPortalContentType 'LICENSE' | Should -Be 'application/octet-stream'
  }
  It 'prints the GitHub Pages portal unless AVD_PORTAL_URL is an https URL' {
    Get-AvdPortalUrl -Url '' | Should -Be 'https://nickprignano.github.io/avd-landing-zone/portal/'
    Get-AvdPortalUrl -Url 'http://x.example/portal/' | Should -Be 'https://nickprignano.github.io/avd-landing-zone/portal/'
    Get-AvdPortalUrl -Url 'https://x.azurestaticapps.net/portal' | Should -Be 'https://x.azurestaticapps.net/portal/'
    Get-AvdPortalUrl -Url 'https://x.example/a b' | Should -Be 'https://nickprignano.github.io/avd-landing-zone/portal/'
  }
}

Describe 'Operator jumpbox (decision 0018)' {
  It 'lists the same Bastion Developer regions as deploy.sh, northcentralus in and eastus out' {
    $regions = Get-AvdBastionDeveloperRegion
    $regions | Should -Contain 'northcentralus'
    $regions | Should -Not -Contain 'eastus'
    $regions | Should -Not -Contain 'southcentralus'
    $sh = Get-Content (Join-Path $PSScriptRoot '../../scripts/deploy/deploy.sh') -Raw
    $line = [regex]::Match($sh, 'BASTION_DEVELOPER_REGIONS=" ([a-z0-9 ]+) "').Groups[1].Value
    @($line -split ' ' | Sort-Object) | Should -Be @($regions | Sort-Object)
  }

  Context 'Get-AvdJumpboxMeterState' {
    # Fixtures omit empty properties the way ARM does (lesson 0021).
    BeforeAll {
      $now = [datetime]::Parse('2026-10-21T12:00:00Z').ToUniversalTime()
      $daily = [pscustomobject]@{ properties = [pscustomobject]@{ status = 'Enabled'; timeZoneId = 'Central Standard Time'; dailyRecurrence = [pscustomobject]@{ time = '2000' } } }
    }
    It 'passes a deallocated jumpbox: only the disk bills' {
      $m = Get-AvdJumpboxMeterState -PowerState 'PowerState/deallocated' -Schedule $daily -Now $now
      $m.Status | Should -Be 'Pass'
      $m.Billing | Should -BeFalse
    }
    It 'passes a running jumpbox with its daily stop' {
      $m = Get-AvdJumpboxMeterState -PowerState 'PowerState/running' -Tags ([pscustomobject]@{ workload = 'avd' }) -Schedule $daily -Now $now
      $m.Status | Should -Be 'Pass'
      $m.Detail | Should -Match '2000 Central Standard Time'
    }
    It 'warns about a VM stopped from inside: compute still bills' {
      (Get-AvdJumpboxMeterState -PowerState 'PowerState/stopped' -Schedule $daily -Now $now).Status | Should -Be 'Warn'
    }
    It 'passes a keep-running time in the future and warns once it is past' {
      $tags = @{ 'avdlz-keep-running-until' = '2026-10-21T18:00Z' }
      (Get-AvdJumpboxMeterState -PowerState 'PowerState/running' -Tags $tags -Now $now).Status | Should -Be 'Pass'
      $late = Get-AvdJumpboxMeterState -PowerState 'PowerState/running' -Tags $tags -Now $now.AddHours(7)
      $late.Status | Should -Be 'Warn'
      $late.Remediation | Should -Match 'Connect-AvdJumpbox.ps1 -Stop'
    }
    It 'warns about a running jumpbox with no daily stop and no keep-running time (no schedule resource at all)' {
      $m = Get-AvdJumpboxMeterState -PowerState 'PowerState/running' -Schedule $null -Now $now
      $m.Status | Should -Be 'Warn'
      $m.DailyStop | Should -BeFalse
    }
  }

  It 'prices the jumpbox at the Linux rate and its Standard SSD, and lists Bastion Developer as free' {
    Mock -ModuleName AvdLandingZone Get-AvdRetailPrice {
      if ($Filter -like "*armSkuName eq 'Standard_B2als_v2'*") {
        [pscustomobject]@{ productName = 'Virtual Machines Basv2 Series'; skuName = 'B2als v2'; meterName = 'B2als v2'; unitOfMeasure = '1 Hour'; retailPrice = 0.04 }
        [pscustomobject]@{ productName = 'Virtual Machines Basv2 Series Windows'; skuName = 'B2als v2'; meterName = 'B2als v2'; unitOfMeasure = '1 Hour'; retailPrice = 0.08 }
      }
      elseif ($Filter -like "*E4 LRS*") { [pscustomobject]@{ productName = 'Standard SSD Managed Disks'; skuName = 'E4 LRS'; meterName = 'E4 LRS Disk'; unitOfMeasure = '1/Month'; retailPrice = 2.4 } }
    }
    $plan = @{ location = 'northcentralus'; sessionHostCount = 1; sessionHostVmSize = 'Standard_E4as_v5'; profileShareQuotaGiB = 100; profileStorageSku = 'Premium_LRS'; connectivityMode = 'HubPeered'; enableAvdPrivateLink = $false
      deployJumpbox = $true; jumpboxVmSize = 'Standard_B2als_v2'; jumpboxAutoShutdownTime = '2000'; jumpboxKeepRunningUntil = '' }
    $e = Get-AvdCostEstimate -Plan $plan -ActiveHoursPerWeek 10
    $j = $e.lines | Where-Object key -eq 'jumpbox'
    $j.unitPrice | Should -Be 0.04
    $j.quantity | Should -Be ([math]::Round(10 * 52 / 12, 1))
    ($e.lines | Where-Object key -eq 'jumpboxdisk').monthly | Should -Be 2.4
    $e.free | Should -Match 'Bastion Developer'
    $plan.jumpboxKeepRunningUntil = '2026-10-22T02:00Z'
    ((Get-AvdCostEstimate -Plan $plan -ActiveHoursPerWeek 10).lines | Where-Object key -eq 'jumpbox').quantity | Should -Be 730
    $plan.deployJumpbox = $false
    $off = Get-AvdCostEstimate -Plan $plan -ActiveHoursPerWeek 10
    ($off.lines + $off.unpriced | ForEach-Object key) | Should -Not -Contain 'jumpbox'
    $off.free.Count | Should -Be 0
  }
}
