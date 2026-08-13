Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectRoot = Split-Path -Parent $PSScriptRoot
$jsonModule = Join-Path $PSScriptRoot 'HermesJsonProjection.psm1'
$ledgerModule = Join-Path $PSScriptRoot 'HermesLedgerTransaction.psm1'
$observationSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\observation-event.schema.json'
$costProjectionSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\cost-projection.schema.json'
$asyncEventSchema = Join-Path $projectRoot 'schemas\schema_registry\v0.2\async-job-event.schema.json'
Import-Module $jsonModule -Force
Import-Module $ledgerModule -Force

function Get-HermesObservationSha256 {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}

function Get-HermesObservationSchemaIdentity {
    param([Parameter(Mandatory)][string]$SchemaId, [Parameter(Mandatory)][string]$SchemaPath)
    [ordered]@{
        schema_id = $SchemaId
        version = '0.2'
        sha256 = (Get-FileHash -LiteralPath $SchemaPath -Algorithm SHA256).Hash
    }
}

function Assert-HermesObservationRoot {
    param([Parameter(Mandatory)][string]$RuntimeRoot)
    $full = [IO.Path]::GetFullPath($RuntimeRoot)
    $cursor = $full
    while (-not [string]::IsNullOrWhiteSpace($cursor)) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Observation path cannot traverse a reparse point.' }
        }
        $next = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($next) -or $next -eq $cursor) { break }
        $cursor = $next
    }
    $full
}

function Get-HermesObservationProperty {
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Document.PSObject.Properties[$Name]) { throw "Observation is missing required field: $Name" }
    $Document.$Name
}

function Get-HermesVerifiedObservationLedgerEvent {
    param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)]$Observation)
    $ledgerPath = Join-Path ([IO.Path]::GetFullPath($RuntimeRoot)) ("tasks\{0}\async_jobs\{1}\job_ledger.jsonl" -f [string]$Observation.task_id, [string]$Observation.async_job_id)
    $null = Assert-HermesObservationRoot $ledgerPath
    $ledger = Get-HermesLedgerSnapshot -LedgerPath $ledgerPath
    $sequence = [int]$Observation.ledger_ref.ledger_sequence
    if ($sequence -lt 1 -or $sequence -gt $ledger.lines.Count) { throw 'Observation ledger_ref sequence is outside the referenced async job Ledger.' }
    $line = [string]$ledger.lines[$sequence - 1]
    $actualSha256 = Get-HermesObservationSha256 $line
    if (-not $actualSha256.Equals([string]$Observation.ledger_ref.ledger_event_sha256, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Observation ledger_ref SHA-256 does not match the referenced async job event bytes.'
    }
    if (-not ($line | Test-Json -SchemaFile $asyncEventSchema -ErrorAction Stop)) { throw 'Observation references an invalid async job event.' }
    $event = $line | ConvertFrom-Json -Depth 100 -ErrorAction Stop
    if ([int]$event.sequence -ne $sequence -or
        [string]$event.async_job_id -cne [string]$Observation.async_job_id -or
        [string]$event.contract_sha256 -cne [string]$Observation.contract_sha256 -or
        [string]$event.provider_id -cne [string]$Observation.provider_id -or
        [string]$event.event_type -cne [string]$Observation.outcome_state -or
        [string]$event.to_state -cne [string]$Observation.outcome_state -or
        [bool]$event.trusted_source -ne $true -or [bool]$event.hermes_completed -ne $false) {
        throw 'Observation does not match one trusted, contract-bound terminal async job event.'
    }
    $event
}

function Invoke-HermesAppendObservation {
    param([Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)]$Observation)
    $root = Assert-HermesObservationRoot $RuntimeRoot
    foreach ($name in @('event_id','timestamp','event_type','business_action','contract_id','contract_sha256','task_id','project_id','provider_id','async_job_id','outcome_state','cost_cny','input_tokens','output_tokens','ledger_sequence','ledger_event_sha256')) {
        $null = Get-HermesObservationProperty $Observation $name
    }
    if ([string]$Observation.task_id -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{2,127}$') { throw 'Observation task_id is not path-safe.' }
    if ([string]$Observation.contract_sha256 -notmatch '^[A-F0-9]{64}$') { throw 'Observation contract SHA-256 binding is invalid.' }
    if ([string]$Observation.ledger_event_sha256 -notmatch '^[A-Fa-f0-9]{64}$') { throw 'Observation ledger reference hash is invalid.' }
    $observationBinding = [pscustomobject]@{
        task_id=[string]$Observation.task_id; async_job_id=[string]$Observation.async_job_id
        contract_sha256=[string]$Observation.contract_sha256; provider_id=[string]$Observation.provider_id
        outcome_state=[string]$Observation.outcome_state
        ledger_ref=[pscustomobject]@{ledger_sequence=[int]$Observation.ledger_sequence;ledger_event_sha256=([string]$Observation.ledger_event_sha256).ToUpperInvariant()}
    }
    $null = Get-HermesVerifiedObservationLedgerEvent -RuntimeRoot $root -Observation $observationBinding
    $eventRoot = Join-Path $root ("tasks\$($Observation.task_id)")
    $null = New-Item -ItemType Directory -Path $eventRoot -Force
    $eventLogPath = Join-Path $eventRoot 'event_log.jsonl'
    $ledger = Get-HermesLedgerSnapshot -LedgerPath $eventLogPath -AllowMissing
    $idempotency = Get-HermesObservationSha256 ('{0}|{1}|{2}|{3}' -f $Observation.event_id, $Observation.contract_id, $Observation.ledger_sequence, ([string]$Observation.ledger_event_sha256).ToUpperInvariant())
    foreach ($line in @($ledger.lines)) {
        $existing = $line | ConvertFrom-Json -Depth 100 -ErrorAction Stop
        if ([string]$existing.event_id -ceq [string]$Observation.event_id) {
            if ([string]$existing.idempotency_key -cne $idempotency) { throw 'Observation event_id conflicts with existing evidence.' }
            return [pscustomobject]@{ appended=$false; event_log_path=$eventLogPath; idempotency_key=$idempotency; token_sha256=$ledger.token_sha256 }
        }
    }
    $document = [ordered]@{
        schema_identity = Get-HermesObservationSchemaIdentity -SchemaId 'hermes.observation_event' -SchemaPath $observationSchema
        event_id = [string]$Observation.event_id
        timestamp = ([DateTimeOffset]::Parse([string]$Observation.timestamp)).ToUniversalTime().ToString('o')
        event_type = [string]$Observation.event_type
        business_action = [string]$Observation.business_action
        contract_id = [string]$Observation.contract_id
        contract_sha256 = [string]$Observation.contract_sha256
        task_id = [string]$Observation.task_id
        project_id = [string]$Observation.project_id
        provider_id = [string]$Observation.provider_id
        async_job_id = [string]$Observation.async_job_id
        outcome_state = [string]$Observation.outcome_state
        cost_cny = [decimal]$Observation.cost_cny
        usage = [ordered]@{ input_tokens=[int]$Observation.input_tokens; output_tokens=[int]$Observation.output_tokens }
        ledger_ref = [ordered]@{ ledger_sequence=[int]$Observation.ledger_sequence; ledger_event_sha256=([string]$Observation.ledger_event_sha256).ToUpperInvariant() }
        idempotency_key = $idempotency
        non_authoritative = $true
    }
    $jsonLine = $document | ConvertTo-Json -Compress -Depth 100
    if (-not ($jsonLine | Test-Json -SchemaFile $observationSchema -ErrorAction Stop)) { throw 'Observation failed schema validation.' }
    $written = Add-HermesLedgerRecord -LedgerPath $eventLogPath -ExpectedToken $ledger.token_sha256 -JsonLine $jsonLine
    [pscustomobject]@{ appended=$true; event_log_path=$eventLogPath; idempotency_key=$idempotency; token_sha256=$written.token_sha256 }
}

function Invoke-HermesRebuildCostProjection {
    param(
        [Parameter(Mandatory)][string]$RuntimeRoot,
        [Parameter(Mandatory)][string]$ProjectionDateUtc,
        [string]$ExpectedToken
    )
    $parsedDate = [DateTime]::MinValue
    if (-not [DateTime]::TryParseExact($ProjectionDateUtc, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedDate)) {
        throw 'ProjectionDateUtc must use yyyy-MM-dd.'
    }
    $root = Assert-HermesObservationRoot $RuntimeRoot
    $receipts = @(
        $tasksRoot = Join-Path $root 'tasks'
        if (Test-Path -LiteralPath $tasksRoot -PathType Container) {
            foreach ($taskDirectory in @(Get-ChildItem -LiteralPath $tasksRoot -Directory -Force)) {
                $eventLogPath = Join-Path $taskDirectory.FullName 'event_log.jsonl'
                if (-not (Test-Path -LiteralPath $eventLogPath -PathType Leaf)) { continue }
                $null = Assert-HermesObservationRoot $eventLogPath
                $eventLog = Get-HermesLedgerSnapshot -LedgerPath $eventLogPath
                foreach ($line in @($eventLog.lines)) {
                    if (-not ($line | Test-Json -SchemaFile $observationSchema -ErrorAction Stop)) { throw 'Cost projection source contains an invalid Observation event.' }
                    $receipt = $line | ConvertFrom-Json -Depth 100 -ErrorAction Stop
                    $null = Get-HermesVerifiedObservationLedgerEvent -RuntimeRoot $root -Observation $receipt
                    $receipt
                }
            }
        }
    )
    $selected = @(
        foreach ($receipt in @($receipts)) {
            $instant = [DateTimeOffset]::Parse([string]$receipt.timestamp).ToUniversalTime()
            if ($instant.ToString('yyyy-MM-dd') -ne $ProjectionDateUtc) { continue }
            if ([string]$receipt.outcome_state -notin @('provider_succeeded','provider_failed','outcome_unknown')) { throw 'Cost receipt outcome is not projectable.' }
            if ([decimal]$receipt.cost_cny -lt 0) { throw 'Cost receipt cannot contain a negative cost.' }
            [pscustomobject][ordered]@{
                event_id = [string]$receipt.event_id
                timestamp = $instant.ToString('o')
                contract_sha256 = [string]$receipt.contract_sha256
                task_id = [string]$receipt.task_id
                provider_id = [string]$receipt.provider_id
                project_id = [string]$receipt.project_id
                async_job_id = [string]$receipt.async_job_id
                outcome_state = [string]$receipt.outcome_state
                cost_cny = [decimal]$receipt.cost_cny
                input_tokens = [int]$receipt.usage.input_tokens
                output_tokens = [int]$receipt.usage.output_tokens
                ledger_sequence = [int]$receipt.ledger_ref.ledger_sequence
                ledger_event_sha256 = [string]$receipt.ledger_ref.ledger_event_sha256
            }
        }
    ) | Sort-Object event_id
    if (@($selected.event_id | Select-Object -Unique).Count -ne $selected.Count) { throw 'Cost projection source receipt event_id values must be unique.' }
    $totals = @(
        foreach ($group in @($selected | Group-Object provider_id,project_id | Sort-Object Name)) {
            $first = $group.Group[0]
            [pscustomobject][ordered]@{
                provider_id = [string]$first.provider_id
                project_id = [string]$first.project_id
                total_cost_cny = [decimal](($group.Group | Measure-Object cost_cny -Sum).Sum)
                total_input_tokens = [int](($group.Group | Measure-Object input_tokens -Sum).Sum)
                total_output_tokens = [int](($group.Group | Measure-Object output_tokens -Sum).Sum)
                call_count = [int]$group.Count
                error_count = [int]@($group.Group | Where-Object outcome_state -eq 'provider_failed').Count
                unknown_count = [int]@($group.Group | Where-Object outcome_state -eq 'outcome_unknown').Count
            }
        }
    )
    $projection = [ordered]@{
        schema_identity = Get-HermesObservationSchemaIdentity -SchemaId 'hermes.cost_projection' -SchemaPath $costProjectionSchema
        projection_date_utc = $ProjectionDateUtc
        source_receipt_count = [int]$selected.Count
        included_outcomes = @($selected.outcome_state | Sort-Object -Unique)
        total_cost_cny = [decimal](($selected | Measure-Object cost_cny -Sum).Sum)
        source_receipts = @($selected)
        totals = @($totals)
        rebuildable = $true
        non_authoritative = $true
    }
    $aggregateRoot = Join-Path $root '_aggregates'
    $null = New-Item -ItemType Directory -Path $aggregateRoot -Force
    $projectionPath = Join-Path $aggregateRoot ("cost_projection_$ProjectionDateUtc.json")
    $snapshot = Get-HermesJsonSnapshot -Path $projectionPath -AllowMissing
    $token = if ([string]::IsNullOrWhiteSpace($ExpectedToken)) { $snapshot.token_sha256 } else { $ExpectedToken }
    $written = Set-HermesJsonProjection -Path $projectionPath -Document $projection -ExpectedToken $token -SchemaPath $costProjectionSchema
    [pscustomobject]@{ projection_path=$projectionPath; previous_token_sha256=$written.previous_token_sha256; token_sha256=$written.token_sha256; source_receipt_count=$selected.Count }
}

function Invoke-HermesObservationWriter {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('AppendObservation', 'RebuildCostProjection')][string]$Action,
        [Parameter(Mandatory)][string]$RuntimeRoot,
        $Observation,
        [string]$ProjectionDateUtc,
        [string]$ExpectedToken
    )
    if ($Action -eq 'AppendObservation') { return Invoke-HermesAppendObservation -RuntimeRoot $RuntimeRoot -Observation $Observation }
    Invoke-HermesRebuildCostProjection -RuntimeRoot $RuntimeRoot -ProjectionDateUtc $ProjectionDateUtc -ExpectedToken $ExpectedToken
}

Export-ModuleMember -Function 'Invoke-HermesObservationWriter'
