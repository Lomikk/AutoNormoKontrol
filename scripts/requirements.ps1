$script:AutoNormoKontrolRequirementChecks = @(
    'profile.handler',
    'document.required-elements',
    'document.element-order',
    'document.visible-element'
)

function Read-RequirementJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Label
    )

    try {
        return [System.IO.File]::ReadAllText(
            $Path,
            [System.Text.Encoding]::UTF8
        ) | ConvertFrom-Json
    }
    catch {
        throw "$Label is not valid JSON: $($_.Exception.Message)"
    }
}

function Get-RequirementProperty {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Name
    )

    return $Object.PSObject.Properties[$Name]
}

function Assert-RequirementString {
    param(
        [object]$Value,
        [Parameter(Mandatory = $true)][string]$Location
    )

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "$Location must be a non-empty string."
    }
}

function Assert-RequirementObjectFields {
    param(
        [Parameter(Mandatory = $true)][object]$Object,
        [Parameter(Mandatory = $true)][string]$Location,
        [Parameter(Mandatory = $true)][string[]]$Allowed,
        [string[]]$Required = @()
    )

    if ($Object -isnot [pscustomobject]) { throw "$Location must be an object." }
    $names = @($Object.PSObject.Properties.Name)
    foreach ($name in $Required) {
        if ($names -notcontains $name) { throw "$Location is missing '$name'." }
    }
    foreach ($name in $names) {
        if ($Allowed -notcontains $name) { throw "$Location contains unknown field '$name'." }
    }
}

function ConvertTo-RequirementStringArray {
    param(
        [object]$Value,
        [Parameter(Mandatory = $true)][string]$Location,
        [switch]$AllowEmpty
    )

    if ($Value -is [string] -or $Value -isnot [System.Array]) {
        throw "$Location must be a JSON array."
    }
    $result = @($Value | ForEach-Object {
        Assert-RequirementString -Value $_ -Location $Location
        [string]$_
    })
    if (-not $AllowEmpty -and $result.Count -eq 0) {
        throw "$Location must not be empty."
    }
    if (@($result | Group-Object | Where-Object Count -ne 1).Count -gt 0) {
        throw "$Location must contain unique values."
    }
    return $result
}

function Resolve-RequirementInputPath {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Location
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        $full = [System.IO.Path]::GetFullPath($Path)
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
            throw "$Location was not found: $full"
        }
        return $full
    }
    return Resolve-ProfileProjectPath -Root $Root -Path $Path -Location $Location -Kind File
}

function Get-RequirementDiagnostics {
    param(
        [Parameter(Mandatory = $true)][object]$Requirement,
        [Parameter(Mandatory = $true)][string]$RequirementId
    )

    $result = [ordered]@{}
    $property = Get-RequirementProperty -Object $Requirement -Name 'diagnostics'
    if ($null -eq $property) { return $result }
    if ($property.Value -isnot [pscustomobject]) {
        throw "$RequirementId.diagnostics must be an object."
    }
    foreach ($diagnosticProperty in $property.Value.PSObject.Properties) {
        $suffix = [string]$diagnosticProperty.Name
        if ($suffix -notmatch '^[A-Z][A-Z0-9_]*$') {
            throw "$RequirementId.diagnostics contains invalid code '$suffix'."
        }
        $diagnostic = $diagnosticProperty.Value
        if ($diagnostic -isnot [pscustomobject]) {
            throw "$RequirementId.diagnostics.$suffix must be an object."
        }
        $names = @($diagnostic.PSObject.Properties.Name)
        foreach ($required in @('message', 'hint')) {
            if ($names -notcontains $required) {
                throw "$RequirementId.diagnostics.$suffix is missing '$required'."
            }
            Assert-RequirementString -Value $diagnostic.$required `
                -Location "$RequirementId.diagnostics.$suffix.$required"
        }
        foreach ($name in $names) {
            if ($name -notin @('message', 'hint')) {
                throw "$RequirementId.diagnostics.$suffix contains unknown field '$name'."
            }
        }
        $code = "$RequirementId/$suffix"
        $result[$code] = [pscustomobject][ordered]@{
            code = $code
            requirement_id = $RequirementId
            message = [string]$diagnostic.message
            hint = [string]$diagnostic.hint
        }
    }
    return $result
}

function Assert-RequirementGraphAcyclic {
    param([object[]]$Edges)

    $adjacency = @{}
    $indegree = @{}
    foreach ($edge in $Edges) {
        $first = [string]$edge.first
        $then = [string]$edge.then
        if (-not $adjacency.ContainsKey($first)) {
            $adjacency[$first] = New-Object System.Collections.Generic.List[string]
        }
        $adjacency[$first].Add($then)
        if (-not $indegree.ContainsKey($first)) { $indegree[$first] = 0 }
        if (-not $indegree.ContainsKey($then)) { $indegree[$then] = 0 }
        $indegree[$then]++
    }
    $queue = New-Object System.Collections.Generic.Queue[string]
    foreach ($node in @($indegree.Keys | Sort-Object)) {
        if ($indegree[$node] -eq 0) { $queue.Enqueue($node) }
    }
    $visited = 0
    while ($queue.Count -gt 0) {
        $node = $queue.Dequeue()
        $visited++
        if (-not $adjacency.ContainsKey($node)) { continue }
        foreach ($target in @($adjacency[$node])) {
            $indegree[$target]--
            if ($indegree[$target] -eq 0) { $queue.Enqueue($target) }
        }
    }
    if ($visited -ne $indegree.Count) {
        throw 'Document element-order constraints contain a cycle.'
    }
}

function Get-AutoNormoKontrolRequirementContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][object]$Profile,
        [string]$InventoryPath = '',
        [string]$RequirementsPath = ''
    )

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if ([string]::IsNullOrWhiteSpace($InventoryPath)) {
        $InventoryPath = [string]$Profile.Data.compliance.inventory
    }
    if ([string]::IsNullOrWhiteSpace($RequirementsPath)) {
        $RequirementsPath = [string]$Profile.Data.compliance.requirements
    }
    $inventoryFull = Resolve-RequirementInputPath -Root $rootFull -Path $InventoryPath `
        -Location 'compliance.inventory'
    $requirementsFull = Resolve-RequirementInputPath -Root $rootFull -Path $RequirementsPath `
        -Location 'compliance.requirements'
    $inventory = Read-RequirementJson -Path $inventoryFull -Label 'Requirement inventory'
    $registry = Read-RequirementJson -Path $requirementsFull -Label 'Profile requirements'

    Assert-RequirementObjectFields -Object $inventory -Location 'inventory' `
        -Allowed @('schema_version', 'source', 'entries') `
        -Required @('schema_version', 'source', 'entries')
    Assert-RequirementObjectFields -Object $inventory.source -Location 'inventory.source' `
        -Allowed @('id', 'title', 'manifest') -Required @('id', 'title', 'manifest')
    Assert-RequirementObjectFields -Object $registry -Location 'requirements' `
        -Allowed @('schema_version', 'profile_id', 'requirements') `
        -Required @('schema_version', 'profile_id', 'requirements')
    Assert-RequirementString $inventory.source.id 'inventory.source.id'
    Assert-RequirementString $inventory.source.title 'inventory.source.title'
    Assert-RequirementString $inventory.source.manifest 'inventory.source.manifest'
    Assert-RequirementString $registry.profile_id 'requirements.profile_id'

    [void](Resolve-RequirementInputPath -Root $rootFull `
        -Path ([string]$inventory.source.manifest) -Location 'inventory.source.manifest'
    )

    if ([int]$inventory.schema_version -ne 2 -or [string]$inventory.schema_version -ne '2') {
        throw "Unsupported requirement inventory schema_version: $($inventory.schema_version)"
    }
    if ([int]$registry.schema_version -ne 2 -or [string]$registry.schema_version -ne '2') {
        throw "Unsupported profile requirements schema_version: $($registry.schema_version)"
    }
    if ([string]$registry.profile_id -ne $Profile.ProfileId) {
        throw "Profile requirements belong to '$($registry.profile_id)', expected '$($Profile.ProfileId)'."
    }
    if ($inventory.entries -is [string] -or $inventory.entries -isnot [System.Array] -or
        @($inventory.entries).Count -eq 0) {
        throw 'Requirement inventory entries must be a non-empty array.'
    }
    if ($registry.requirements -is [string] -or $registry.requirements -isnot [System.Array] -or
        @($registry.requirements).Count -eq 0) {
        throw 'Profile requirements must be a non-empty array.'
    }

    $inventoryById = @{}
    foreach ($entry in @($inventory.entries)) {
        $id = [string]$entry.id
        Assert-RequirementObjectFields -Object $entry -Location 'inventory.entries[]' `
            -Allowed @('id', 'kind', 'clause', 'summary', 'artifact') `
            -Required @('id', 'kind', 'clause', 'summary')
        Assert-RequirementString -Value $id -Location 'inventory.entries[].id'
        if ($inventoryById.ContainsKey($id)) { throw "Duplicate inventory id: $id" }
        Assert-RequirementString -Value $entry.clause -Location "$id.clause"
        Assert-RequirementString -Value $entry.summary -Location "$id.summary"
        if ([string]$entry.kind -notin @('requirement', 'definition', 'group', 'example', 'form')) {
            throw "$id.kind has unsupported value '$($entry.kind)'."
        }
        $artifactProperty = Get-RequirementProperty -Object $entry -Name 'artifact'
        if ($null -ne $artifactProperty) {
            Assert-RequirementString -Value $artifactProperty.Value -Location "$id.artifact"
        }
        $inventoryById[$id] = $entry
    }

    $requirementsById = @{}
    $semanticItems = New-Object System.Collections.Generic.List[object]
    $externalItems = New-Object System.Collections.Generic.List[object]
    $diagnostics = [ordered]@{}
    $requiredElements = New-Object System.Collections.Generic.List[object]
    $requiredElementKeys = @{}
    $orderEdges = New-Object System.Collections.Generic.List[object]
    $visibleElements = New-Object System.Collections.Generic.List[object]
    $semanticIds = @{}
    $externalIds = @{}

    foreach ($requirement in @($registry.requirements)) {
        $id = [string]$requirement.id
        Assert-RequirementObjectFields -Object $requirement -Location 'requirements[]' `
            -Allowed @('id', 'source_ref', 'origin', 'summary', 'disposition', 'scope',
                'verification', 'diagnostics', 'coverage', 'notes') `
            -Required @('id', 'disposition', 'scope', 'verification', 'notes')
        Assert-RequirementString -Value $id -Location 'requirements[].id'
        if ($requirementsById.ContainsKey($id)) { throw "Duplicate profile requirement id: $id" }
        $requirementsById[$id] = $requirement
        $sourceRefProperty = Get-RequirementProperty -Object $requirement -Name 'source_ref'
        $originProperty = Get-RequirementProperty -Object $requirement -Name 'origin'
        if (($null -eq $sourceRefProperty) -eq ($null -eq $originProperty)) {
            throw "$id must declare exactly one of source_ref or origin."
        }
        if ($null -ne $sourceRefProperty) {
            if ([string]$requirement.source_ref -ne $id -or -not $inventoryById.ContainsKey($id)) {
                throw "$id.source_ref must resolve to the same canonical inventory id."
            }
        }
        else {
            if ($inventoryById.ContainsKey($id)) {
                throw "$id.origin cannot replace an existing canonical source entry."
            }
            Assert-RequirementObjectFields -Object $requirement.origin -Location "$id.origin" `
                -Allowed @('kind', 'source', 'locator') -Required @('kind', 'source', 'locator')
            if ([string]$requirement.origin.kind -notin @('profile', 'department', 'teacher', 'user')) {
                throw "$id.origin.kind has unsupported value '$($requirement.origin.kind)'."
            }
            Assert-RequirementString $requirement.origin.source "$id.origin.source"
            Assert-RequirementString $requirement.origin.locator "$id.origin.locator"
            Assert-RequirementString $requirement.summary "$id.summary"
        }
        $disposition = [string]$requirement.disposition
        if ($disposition -notin @('applicable', 'conditional', 'formal', 'not-applicable')) {
            throw "$id.disposition has unsupported value '$disposition'."
        }
        Assert-RequirementString -Value $requirement.scope -Location "$id.scope"
        Assert-RequirementString -Value $requirement.notes -Location "$id.notes"
        if ($requirement.verification -is [string] -or $requirement.verification -isnot [System.Array]) {
            throw "$id.verification must be a JSON array."
        }
        $verifications = @($requirement.verification)
        if ($disposition -in @('formal', 'not-applicable') -and $verifications.Count -ne 0) {
            throw "$id is $disposition and therefore cannot declare verification handlers."
        }
        if ($disposition -in @('applicable', 'conditional') -and $verifications.Count -eq 0) {
            throw "$id is $disposition and must declare at least one verification handler."
        }

        $requirementDiagnostics = Get-RequirementDiagnostics -Requirement $requirement -RequirementId $id
        foreach ($code in $requirementDiagnostics.Keys) {
            if ($diagnostics.Contains($code)) { throw "Duplicate diagnostic code: $code" }
            $diagnostics[$code] = $requirementDiagnostics[$code]
        }

        foreach ($verification in $verifications) {
            $kind = [string]$verification.kind
            switch ($kind) {
                'programmatic' {
                    Assert-RequirementObjectFields -Object $verification `
                        -Location "$id.verification.programmatic" `
                        -Allowed @('kind', 'check', 'parameters', 'diagnostic', 'severity') `
                        -Required @('kind', 'check', 'severity')
                    $check = [string]$verification.check
                    if ($check -notin $script:AutoNormoKontrolRequirementChecks) {
                        throw "$id uses unknown programmatic check '$check'."
                    }
                    $severity = [string]$verification.severity
                    if ($severity -notin @('error', 'warning')) {
                        throw "$id programmatic check '$check' has unsupported severity '$severity'."
                    }
                    $diagnostic = [string]$verification.diagnostic
                    if ($check -ne 'profile.handler') {
                        Assert-RequirementString -Value $diagnostic -Location "$id.$check.diagnostic"
                        if (-not $diagnostics.Contains($diagnostic)) {
                            throw "$id programmatic check '$check' references unknown diagnostic '$diagnostic'."
                        }
                    }
                    $parameters = $verification.parameters
                    if ($null -eq $parameters) { $parameters = [pscustomobject]@{} }
                    if ($parameters -isnot [pscustomobject]) {
                        throw "$id programmatic check '$check' parameters must be an object."
                    }
                    switch ($check) {
                        'document.required-elements' {
                            Assert-RequirementObjectFields -Object $parameters `
                                -Location "$id.$check.parameters" -Allowed @('elements') `
                                -Required @('elements')
                            $elements = @(ConvertTo-RequirementStringArray -Value $parameters.elements `
                                -Location "$id.$check.parameters.elements")
                            foreach ($element in $elements) {
                                if ($element -notmatch '^[a-z][a-z0-9-]*$') {
                                    throw "$id declares invalid document element '$element'."
                                }
                                $elementKey = $id + [char]0 + $element
                                if (-not $requiredElementKeys.ContainsKey($elementKey)) {
                                    $requiredElementKeys[$elementKey] = $true
                                    $requiredElements.Add([pscustomobject][ordered]@{
                                        id = $element
                                        requirement_id = $id
                                        diagnostic = $diagnostic
                                    })
                                }
                            }
                        }
                        'document.element-order' {
                            Assert-RequirementObjectFields -Object $parameters `
                                -Location "$id.$check.parameters" -Allowed @('first', 'then') `
                                -Required @('first', 'then')
                            Assert-RequirementString $parameters.first "$id.$check.parameters.first"
                            Assert-RequirementString $parameters.then "$id.$check.parameters.then"
                            if ([string]$parameters.first -eq [string]$parameters.then) {
                                throw "$id document.element-order cannot compare an element with itself."
                            }
                            $orderEdges.Add([pscustomobject][ordered]@{
                                requirement_id = $id
                                first = [string]$parameters.first
                                then = [string]$parameters.then
                                diagnostic = $diagnostic
                            })
                        }
                        'document.visible-element' {
                            Assert-RequirementObjectFields -Object $parameters `
                                -Location "$id.$check.parameters" `
                                -Allowed @('element', 'text', 'required') `
                                -Required @('element', 'text', 'required')
                            Assert-RequirementString $parameters.element "$id.$check.parameters.element"
                            Assert-RequirementString $parameters.text "$id.$check.parameters.text"
                            $requiredProperty = Get-RequirementProperty -Object $parameters -Name 'required'
                            if ($null -eq $requiredProperty -or $requiredProperty.Value -isnot [bool]) {
                                throw "$id.$check.parameters.required must be a boolean."
                            }
                            $visibleElements.Add([pscustomobject][ordered]@{
                                requirement_id = $id
                                element = [string]$parameters.element
                                text = [string]$parameters.text
                                required = [bool]$parameters.required
                                diagnostic = $diagnostic
                            })
                        }
                    }
                }
                'semantic' {
                    Assert-RequirementObjectFields -Object $verification `
                        -Location "$id.verification.semantic" `
                        -Allowed @('kind', 'review_id', 'question', 'evidence_required') `
                        -Required @('kind', 'review_id', 'question', 'evidence_required')
                    $reviewId = if ([string]::IsNullOrWhiteSpace([string]$verification.review_id)) {
                        $id
                    } else { [string]$verification.review_id }
                    if ($semanticIds.ContainsKey($reviewId)) {
                        throw "Duplicate semantic review id: $reviewId"
                    }
                    Assert-RequirementString -Value $verification.question -Location "$id.semantic.question"
                    if ($verification.evidence_required -isnot [bool]) {
                        throw "$id.semantic.evidence_required must be a boolean."
                    }
                    $semanticIds[$reviewId] = $true
                    $semanticItems.Add([pscustomobject][ordered]@{
                        id = $reviewId
                        requirement_id = $id
                        applicability = $disposition
                        question = [string]$verification.question
                        evidence_required = [bool]$verification.evidence_required
                    })
                }
                'external' {
                    Assert-RequirementObjectFields -Object $verification `
                        -Location "$id.verification.external" `
                        -Allowed @('kind', 'review_id', 'required_evidence') `
                        -Required @('kind', 'review_id', 'required_evidence')
                    $reviewId = if ([string]::IsNullOrWhiteSpace([string]$verification.review_id)) {
                        $id
                    } else { [string]$verification.review_id }
                    if ($externalIds.ContainsKey($reviewId)) {
                        throw "Duplicate external acceptance id: $reviewId"
                    }
                    Assert-RequirementString -Value $verification.required_evidence `
                        -Location "$id.external.required_evidence"
                    $externalIds[$reviewId] = $true
                    $externalItems.Add([pscustomobject][ordered]@{
                        id = $reviewId
                        requirement_id = $id
                        required_evidence = [string]$verification.required_evidence
                    })
                }
                default { throw "$id uses unknown verification kind '$kind'." }
            }
        }

        $programmatic = @($verifications | Where-Object kind -eq 'programmatic')
        if ($programmatic.Count -gt 0) {
            if ($requirement.coverage -isnot [pscustomobject]) {
                throw "$id has programmatic verification but no coverage object."
            }
            Assert-RequirementObjectFields -Object $requirement.coverage `
                -Location "$id.coverage" `
                -Allowed @('implementation_markers', 'test_markers') `
                -Required @('implementation_markers', 'test_markers')
            foreach ($coverageName in @('implementation_markers', 'test_markers')) {
                $markers = @(ConvertTo-RequirementStringArray `
                    -Value $requirement.coverage.$coverageName `
                    -Location "$id.coverage.$coverageName")
                if ($markers -notcontains $id) {
                    throw "$id.coverage.$coverageName must contain the requirement id."
                }
            }
        }
    }

    foreach ($id in $inventoryById.Keys) {
        if (-not $requirementsById.ContainsKey($id)) {
            throw "${id}: canonical inventory entry is missing from profile requirements."
        }
    }
    Assert-RequirementGraphAcyclic -Edges $orderEdges.ToArray()

    return [pscustomobject][ordered]@{
        schema_version = 2
        profile_id = $Profile.ProfileId
        inventory = [pscustomobject][ordered]@{
            path = $InventoryPath.Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $inventoryFull -Algorithm SHA256).Hash.ToLowerInvariant()
            document = $inventory
        }
        registry = [pscustomobject][ordered]@{
            path = $RequirementsPath.Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $requirementsFull -Algorithm SHA256).Hash.ToLowerInvariant()
            document = $registry
        }
        requirements = @($registry.requirements)
        semantic_items = $semanticItems.ToArray()
        external_items = $externalItems.ToArray()
        diagnostics = [pscustomobject]$diagnostics
        structure = [pscustomobject][ordered]@{
            required_elements = $requiredElements.ToArray()
            order = $orderEdges.ToArray()
            visible_elements = $visibleElements.ToArray()
        }
    }
}

function ConvertTo-RequirementYamlString {
    param([object]$Value)
    return ($Value | ConvertTo-Json -Compress)
}

function Write-AutoNormoKontrolRequirementMetadata {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][string]$JsonPath,
        [Parameter(Mandatory = $true)][string]$YamlPath
    )

    $encoding = New-Object System.Text.UTF8Encoding($false)
    $jsonDirectory = Split-Path -Parent $JsonPath
    $yamlDirectory = Split-Path -Parent $YamlPath
    if ($jsonDirectory) { New-Item -ItemType Directory -Force -Path $jsonDirectory | Out-Null }
    if ($yamlDirectory) { New-Item -ItemType Directory -Force -Path $yamlDirectory | Out-Null }
    $serializable = [pscustomobject][ordered]@{
        schema_version = $Contract.schema_version
        profile_id = $Contract.profile_id
        inventory = [pscustomobject][ordered]@{
            path = $Contract.inventory.path
            sha256 = $Contract.inventory.sha256
        }
        registry = [pscustomobject][ordered]@{
            path = $Contract.registry.path
            sha256 = $Contract.registry.sha256
        }
        semantic_items = @($Contract.semantic_items)
        external_items = @($Contract.external_items)
        diagnostics = $Contract.diagnostics
        structure = $Contract.structure
    }
    [System.IO.File]::WriteAllText(
        $JsonPath,
        ($serializable | ConvertTo-Json -Depth 20),
        $encoding
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('# Generated from compliance.inventory + compliance.requirements. Do not edit.')
    $lines.Add('profile-inventory:')
    $lines.Add('  profile-id: ' + (ConvertTo-RequirementYamlString $Contract.profile_id))
    if (@($Contract.semantic_items).Count -eq 0) {
        $lines.Add('  semantic-rule-ids: []')
    }
    else {
        $lines.Add('  semantic-rule-ids:')
        foreach ($item in @($Contract.semantic_items)) {
            $lines.Add('    - ' + (ConvertTo-RequirementYamlString $item.id))
        }
    }
    if (@($Contract.external_items).Count -eq 0) {
        $lines.Add('  external-item-ids: []')
    }
    else {
        $lines.Add('  external-item-ids:')
        foreach ($item in @($Contract.external_items)) {
            $lines.Add('    - ' + (ConvertTo-RequirementYamlString $item.id))
        }
    }
    $lines.Add('profile-structure:')
    $lines.Add('  required-elements:')
    foreach ($item in @($Contract.structure.required_elements)) {
        $lines.Add('    - id: ' + (ConvertTo-RequirementYamlString $item.id))
        $lines.Add('      requirement-id: ' + (ConvertTo-RequirementYamlString $item.requirement_id))
        $lines.Add('      diagnostic: ' + (ConvertTo-RequirementYamlString $item.diagnostic))
    }
    $lines.Add('  element-order:')
    foreach ($item in @($Contract.structure.order)) {
        $lines.Add('    - requirement-id: ' + (ConvertTo-RequirementYamlString $item.requirement_id))
        $lines.Add('      first: ' + (ConvertTo-RequirementYamlString $item.first))
        $lines.Add('      then: ' + (ConvertTo-RequirementYamlString $item.then))
        $lines.Add('      diagnostic: ' + (ConvertTo-RequirementYamlString $item.diagnostic))
    }
    $lines.Add('profile-diagnostics:')
    foreach ($property in $Contract.diagnostics.PSObject.Properties) {
        $item = $property.Value
        $lines.Add('  - code: ' + (ConvertTo-RequirementYamlString $item.code))
        $lines.Add('    requirement-id: ' + (ConvertTo-RequirementYamlString $item.requirement_id))
        $lines.Add('    message: ' + (ConvertTo-RequirementYamlString $item.message))
        $lines.Add('    hint: ' + (ConvertTo-RequirementYamlString $item.hint))
    }
    [System.IO.File]::WriteAllText($YamlPath, ($lines -join "`n") + "`n", $encoding)
}

function New-AutoNormoKontrolReviewJournals {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][object]$Contract,
        [Parameter(Mandatory = $true)][string]$DocumentType,
        [Parameter(Mandatory = $true)][string]$SemanticPath,
        [Parameter(Mandatory = $true)][string]$ExternalPath
    )

    foreach ($path in @($SemanticPath, $ExternalPath)) {
        if (Test-Path -LiteralPath $path) {
            throw "Review journal already exists and will not be overwritten: $path"
        }
        $directory = Split-Path -Parent $path
        if ($directory) { New-Item -ItemType Directory -Force -Path $directory | Out-Null }
    }
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $semantic = New-Object System.Collections.Generic.List[string]
    $semantic.Add('# Generated skeleton. Statuses and evidence require a real semantic review.')
    $semantic.Add('semantic-review:')
    $semantic.Add('  status: uncertain')
    $semantic.Add('  content-hash: ""')
    $semantic.Add('  reviewed-at: ""')
    $semantic.Add('  reviewer: ""')
    $semantic.Add('  document-type: ' + (ConvertTo-RequirementYamlString $DocumentType))
    $semantic.Add('  allowed-rule-statuses: [pass, fail, uncertain, not-applicable]')
    if (@($Contract.semantic_items).Count -eq 0) {
        $semantic.Add('  rules: []')
    }
    else {
        $semantic.Add('  rules:')
        foreach ($item in @($Contract.semantic_items)) {
            $semantic.Add('    - id: ' + (ConvertTo-RequirementYamlString $item.id))
            $semantic.Add('      applicability: ' + (ConvertTo-RequirementYamlString $item.applicability))
            $semantic.Add('      status: uncertain')
            $semantic.Add('      evidence: []')
            $semantic.Add('      note: ' + (ConvertTo-RequirementYamlString $item.question))
        }
    }
    [System.IO.File]::WriteAllText($SemanticPath, ($semantic -join "`n") + "`n", $encoding)

    $external = New-Object System.Collections.Generic.List[string]
    $external.Add('# Generated skeleton. Only real external decisions may close these items.')
    $external.Add('external-acceptance:')
    $external.Add('  status: pending')
    $external.Add('  profile-id: ' + (ConvertTo-RequirementYamlString $Contract.profile_id))
    $external.Add('  accepted-by: ""')
    $external.Add('  accepted-at: ""')
    $external.Add('  evidence-set-hash: ""')
    if (@($Contract.external_items).Count -eq 0) {
        $external.Add('  items: []')
    }
    else {
        $external.Add('  items:')
        foreach ($item in @($Contract.external_items)) {
            $external.Add('    - id: ' + (ConvertTo-RequirementYamlString $item.id))
            $external.Add('      status: pending')
            $external.Add('      required-evidence: ' + (ConvertTo-RequirementYamlString $item.required_evidence))
            $external.Add('      evidence: []')
            $external.Add('      decision: ""')
        }
    }
    [System.IO.File]::WriteAllText($ExternalPath, ($external -join "`n") + "`n", $encoding)
}
