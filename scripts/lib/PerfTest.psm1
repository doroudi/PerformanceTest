<#
Shared helpers for the k6 runners.

This module exists so that the two entry points - k6/run-test.ps1 (local
docker-compose authoring) and scripts/deploy-and-test.ps1 (Kubernetes runs) -
agree on three things that would otherwise drift apart:

  * which test types exist (read from the scenarios directory, so a `-TestType`
    that has no script fails with a useful message instead of a docker/kubectl
    error),
  * how a k6 summary is cut out of a log and turned into results/summary.json,
  * how files are written (UTF-8 without a BOM: a BOM in a YAML manifest makes
    kubectl fail with a bewildering parse error).
#>

$script:SummaryBeginMarker = '===K6_SUMMARY_JSON_BEGIN==='
$script:SummaryEndMarker = '===K6_SUMMARY_JSON_END==='
$script:SummarySchema = 'perftest.summary/v1'

function Get-PerfTestRepoRoot {
    <# The kit's root directory (the module lives in scripts/lib). #>
    [CmdletBinding()]
    param()

    return (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
}

function Get-PerfTestSummaryMarkers {
    [CmdletBinding()]
    param()

    return [pscustomobject]@{
        Begin  = $script:SummaryBeginMarker
        End    = $script:SummaryEndMarker
        Schema = $script:SummarySchema
    }
}

function Write-Utf8NoBom {
    <# Write a text file as UTF-8 with no byte order mark, creating parent directories. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string] $Content
    )

    $directory = Split-Path -Parent $Path
    if ($directory -and -not (Test-Path $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
    return $Path
}

function Get-PerfTestTypes {
    <#
    The available test types, derived from the scenario files on disk.

    Deriving them instead of hardcoding a ValidateSet is deliberate: a list in the
    script drifts from the directory, and `-TestType load` used to be accepted
    while no load-test.js existed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ScenariosDirectory
    )

    if (-not (Test-Path $ScenariosDirectory -PathType Container)) {
        throw "Scenarios directory not found: $ScenariosDirectory"
    }

    return @(
        Get-ChildItem -Path $ScenariosDirectory -Filter '*-test.js' -File |
            Sort-Object Name |
            ForEach-Object { $_.Name -replace '-test\.js$', '' }
    )
}

function Resolve-PerfTestScenario {
    <# Resolve a test type to its scenario file, or fail listing what is available. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $TestType,
        [Parameter(Mandatory = $true)][string] $ScenariosDirectory
    )

    $available = Get-PerfTestTypes -ScenariosDirectory $ScenariosDirectory
    if ($available -notcontains $TestType) {
        throw ("Unknown test type '$TestType'. Available test types: {0}." -f ($available -join ', '))
    }

    return (Join-Path $ScenariosDirectory "$TestType-test.js")
}

function Resolve-PerfTestUsersFile {
    <#
    Find the credential pool file.

    Precedence: an explicit path, then a JOURNEY_USERS_FILE entry from the environment file,
    then k6\users.json next to k6\.env. Returns '' when there is none, because a pool is
    optional - a run with a single account is still a valid run.

    An explicit path that does not exist is an ERROR rather than a silent fallback: "I
    pointed at my users file and it used another one / it used nothing" is the failure this
    avoids, and with credentials the silent version means measuring one account while
    believing you measured thirty.
    #>
    [CmdletBinding()]
    param(
        [string] $ExplicitPath,
        [string[]] $SearchPaths = @(),
        [hashtable] $Environment = @{}
    )

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        if (-not (Test-Path $ExplicitPath -PathType Leaf)) {
            throw "-UsersFile was not found: $ExplicitPath"
        }
        return (Resolve-Path $ExplicitPath).Path
    }

    foreach ($name in @('JOURNEY_USERS_FILE', 'USERS_FILE')) {
        if ($Environment.ContainsKey($name) -and -not [string]::IsNullOrWhiteSpace("$($Environment[$name])")) {
            $candidate = "$($Environment[$name])"
            if (-not (Test-Path $candidate -PathType Leaf)) {
                throw "The environment file sets $name=$candidate, but that file does not exist."
            }
            return (Resolve-Path $candidate).Path
        }
    }

    foreach ($candidate in $SearchPaths) {
        if (Test-Path $candidate -PathType Leaf) {
            return (Resolve-Path $candidate).Path
        }
    }

    return ''
}

function Read-PerfTestUsersFile {
    <#
    Read a credential pool and return its JSON text, ready to hand to k6 as
    JOURNEY_USERS_JSON.

    The text is passed through unchanged on purpose: the per-entry rules (which key names
    mean the account and the password, duplicates, the "username:password" shorthand) live
    in k6/scripts/lib/users.js, and are checked there by k6/tests/users.test.mjs. Checking
    them again here would mean two definitions of a valid file, and the one that drifted
    would be the one nobody tested.

    What IS checked here is what can be checked without a cluster: the file exists, is JSON,
    and contains at least one account. Those are the mistakes that would otherwise cost a
    whole run - a typo'd path, a trailing comma, an empty array.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $Path)

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "The credential pool file was not found: $Path"
    }

    $text = Get-Content -Path $Path -Raw
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "The credential pool file is empty: $Path"
    }

    $parsed = $null
    try {
        $parsed = $text | ConvertFrom-Json
    }
    catch {
        throw ("The credential pool file is not valid JSON: $Path`n$($_.Exception.Message)`n" +
            'It should look like: [{"username":"a@example.com","password":"..."}, ...]')
    }

    $entries = @()
    if ($parsed -is [array]) { $entries = @($parsed) }
    elseif ($parsed -and $parsed.users) { $entries = @($parsed.users) }

    if ($entries.Count -eq 0) {
        throw ("The credential pool file contains no accounts: $Path`n" +
            'It must be a JSON array of accounts, or an object with a "users" array.')
    }

    return $text
}

function Get-PerfTestHostAddress {
    <#
    Resolve a hostname on THIS machine and return its first IPv4 address.

    Why the runner resolves it instead of letting the cluster do it: inside a cluster,
    names go through the cluster's DNS, and that resolver may not reach external names at
    all. Measured on a real minikube here, a k6 pod asking for the identity provider got
    `lookup tc-idp-api.nt-development.dev on 10.96.0.10:53: server misbehaving` while
    CoreDNS logged `read udp 10.244.0.2:51398->192.168.65.254:53: i/o timeout`, and the
    same name resolved perfectly from the host. Every authenticated scenario therefore
    died before its first request, for a reason no part of the test controlled.

    Resolving where DNS does work and pinning the address into the Job's /etc/hosts takes
    the cluster's resolver out of the path. Returns $null when the name cannot be
    resolved, so a caller can warn and carry on rather than failing a run over a lookup it
    may not have needed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $HostName)

    try {
        $addresses = [System.Net.Dns]::GetHostAddresses($HostName)
    }
    catch {
        return $null
    }

    foreach ($address in $addresses) {
        if ($address.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $address.IPAddressToString
        }
    }

    return $null
}

function Test-PerfTestTcpEndpoint {
    <#
    Can this machine open a TCP connection to host:port? Fast, and never throws.

    Why it exists: a NodePort is opened on the NODE's network, not on the host's loopback.
    On Docker Desktop's built-in Kubernetes a NodePort does answer on 127.0.0.1, which is
    where the `http://127.0.0.1:30030` line in this kit came from - but on minikube (whose
    nodes sit on 192.168.49.0/24, inside a VM) and on kind, that address refuses the
    connection. Printing a URL anyway sends people to a dead link and makes a working
    Grafana look broken, so the scripts ask this first and offer a route that works
    instead of asserting one that may not.
    #>
    [CmdletBinding()]
    param(
        [string] $ComputerName = '127.0.0.1',
        [Parameter(Mandatory = $true)][int] $Port,
        [int] $TimeoutMilliseconds = 800
    )

    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect($ComputerName, $Port, $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) {
            return $false
        }
        # EndConnect throws when the connection was refused, which is the answer we want.
        $client.EndConnect($connect)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Dispose()
    }
}

function Get-PerfTestFreeLocalPort {
    <#
    The first candidate port that nothing on this machine answers on.

    For a `kubectl port-forward`, where "free" means two things at once: the forward has to
    be able to bind it, and whatever IS on it must not be mistaken for the thing being
    forwarded. The second is the one that bites - the compose stack already publishes its
    own Grafana on 127.0.0.1:3000, so forwarding in-cluster Grafana to 3000 either fails
    with "address already in use" or, if it somehow binds, shows the COMPOSE dashboard,
    which queries the compose Prometheus and reports "No data" for a cluster run. That
    looks exactly like a broken in-cluster metrics pipeline.

    Returns $null when every candidate is taken, so the caller can print the port as a
    placeholder rather than pretending to know.
    #>
    [CmdletBinding()]
    param([int[]] $Candidate = @(3000, 3001, 3002, 3003, 3004))

    foreach ($port in $Candidate) {
        if (-not (Test-PerfTestTcpEndpoint -Port $port)) {
            return $port
        }
    }

    return $null
}

function New-PerfTestId {
    <#
    The identifier for one run: <utc timestamp>-<type>, e.g. 20261005-070829-load.

    One function, two consumers, deliberately: the results directory is named after it
    AND the k6 Job is tagged with it, so a Grafana series and the artefact that explains
    it name each other. Computing the same string in two places is how those drift
    apart, and the symptom is a Grafana link that filters to nothing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string] $TestType)

    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $safeName = ($TestType -replace '[^A-Za-z0-9\-_]', '-')

    return "$stamp-$safeName"
}

function New-PerfTestRunDirectory {
    <#
    Create results/<utc timestamp>-<name>/ for one run.

    Every run gets its own directory so that a run can never overwrite the
    evidence from the run before it, and results/latest.txt points at the newest
    one so the compare script can be called without hunting for a path.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $ResultsRoot,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $runDirectory = Join-Path $ResultsRoot (New-PerfTestId -TestType $Name)

    if (-not (Test-Path $runDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
    }

    Write-Utf8NoBom -Path (Join-Path $ResultsRoot 'latest.txt') -Content $runDirectory | Out-Null
    return $runDirectory
}

function Get-K6SummaryJsonFromText {
    <#
    Cut the machine-readable summary out of k6 output and return it as raw JSON text.

    k6/scripts/lib/summary.js prints the JSON between two markers, so the same
    parsing works for `docker compose run` output and for `kubectl logs`. Returning
    the text (rather than the parsed object) lets callers archive exactly what was
    measured, without a round-trip through PowerShell's serializer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string] $Text
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw "k6 produced no output, so there is no summary to read. Check the raw log for an image pull or startup failure."
    }

    $pattern = '(?s)' + [regex]::Escape($script:SummaryBeginMarker) + '(?<json>.*?)' + [regex]::Escape($script:SummaryEndMarker)
    $match = [regex]::Match($Text, $pattern)

    if (-not $match.Success) {
        $tail = ($Text -split "`r?`n" | Select-Object -Last 20) -join "`n"
        throw ("k6 output contained no summary block ({0} ... {1}). The run probably failed before the end-of-test summary.`nLast lines of output:`n{2}" -f `
                $script:SummaryBeginMarker, $script:SummaryEndMarker, $tail)
    }

    return $match.Groups['json'].Value.Trim()
}

function Get-K6SummaryFromText {
    <# Same as Get-K6SummaryJsonFromText, but parsed into an object. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][AllowNull()][string] $Text
    )

    $json = Get-K6SummaryJsonFromText -Text $Text

    try {
        return ($json | ConvertFrom-Json)
    }
    catch {
        throw ("The summary block was found but is not valid JSON: {0}" -f $_.Exception.Message)
    }
}

function Get-K6SummaryFromFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        throw "Log file not found: $Path"
    }

    return (Get-K6SummaryFromText -Text (Get-Content -Path $Path -Raw))
}

function Write-PerfTestMetadata {
    <# Record what was run, against what, and with which knobs - next to the results. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][hashtable] $Data
    )

    $json = $Data | ConvertTo-Json -Depth 8
    return (Write-Utf8NoBom -Path $Path -Content $json)
}

function ConvertTo-PerfTestEnvTable {
    <#
    Parse a -EnvVars argument into a name -> value table.

    Both documented invocation styles must behave identically:

        # in-process: PowerShell splits the commas itself
        ./k6/run-test.ps1  -EnvVars TARGET_VUS=20,HOLD_DURATION=5m

        # pwsh -File: PowerShell does NOT split the commas
        pwsh -File k6/run-test.ps1 -EnvVars TARGET_VUS=20,HOLD_DURATION=5m

    The second form is the one every README example uses, and it delivers the
    whole "TARGET_VUS=20,HOLD_DURATION=5m" as a SINGLE array element. A runner
    that only iterated the array therefore set TARGET_VUS to the string
    "20,HOLD_DURATION=5m" and handed k6 a number that was not a number - which
    surfaced as `TARGET_VUS must be a non-negative number, but got
    "20,HOLD_DURATION=5m"`, a message that points at the scenario file rather
    than at the argument parsing. Splitting every element on commas makes the
    two styles agree.

    Consequence worth knowing: a value cannot itself contain a comma. None of
    the scenario knobs do.
    #>
    [CmdletBinding()]
    param(
        [string[]] $EnvVars = @()
    )

    $table = @{}
    foreach ($element in $EnvVars) {
        foreach ($part in ("$element" -split ',')) {
            $entry = $part.Trim()
            if ($entry -eq '') {
                continue
            }
            if ($entry -notmatch '^(?<name>[A-Za-z_][A-Za-z0-9_]*)=(?<value>.*)$') {
                throw ("EnvVars entries must look like NAME=value, but got '{0}'. " +
                    'Separate several entries with commas: -EnvVars TARGET_VUS=20,HOLD_DURATION=5m' -f $entry)
            }
            $table[$Matches['name']] = $Matches['value']
        }
    }

    return $table
}

function Protect-PerfTestSecretValues {
    <#
    Mask credential-looking values before they are written into an artefact.

    Every runner records the run's environment variables in meta.json, because "which
    knobs produced this number" is part of the result. That is right for
    TARGET_VUS=50 and wrong for JOURNEY_PASSWORD: the value ends up in
    results/<run>/meta.json, sitting in a directory full of files people share, attach
    to tickets and paste into chat. The same applies to AUTH_CLIENT_SECRET and any
    bearer token passed through REQUEST_HEADERS.

    Names are matched case-insensitively against the usual suspects, so this works for
    credentials the kit has never heard of, without anyone having to remember to
    declare them. The KEY is kept and only the value is replaced, so meta.json still
    records that a password was supplied - which is what makes a run reproducible -
    without recording which one.

    Returns a NEW hashtable; the caller's table is left alone so the real values can
    still be handed to the container.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][AllowNull()][hashtable] $Environment
    )

    if ($null -eq $Environment) {
        return @{}
    }

    # PASSWORD covers JOURNEY_PASSWORD, DB_PASSWORD, SA_PASSWORD...; SECRET covers
    # AUTH_CLIENT_SECRET and X-Auth-Secret; TOKEN covers bearer tokens and
    # VAULT_TOKEN_ID; APIKEY/API_KEY and CREDENTIAL cover the rest.
    $secretNamePattern = '(?i)(password|passwd|pwd|secret|token|apikey|api_key|credential|authorization|connectionstring|connection_string)'

    # The name is not always the giveaway. REQUEST_HEADERS is a perfectly innocent name
    # whose VALUE is routinely `Authorization: Bearer ...`, and an env var carrying a
    # JSON login body has the password nested inside it:
    #
    #   {"Email":"a@b.c","Password":"nested-secret"}
    #
    # hence the optional quotes around the separator. A value that looks like it carries
    # a credential is redacted even when its name looks harmless.
    $secretValuePattern = '(?i)(bearer\s+\S|basic\s+\S|(password|passwd|secret|token|apikey|api_key|authorization|credential|connectionstring)["'']?\s*[:=]\s*["'']?\S)'

    $masked = @{}
    foreach ($name in $Environment.Keys) {
        $value = $Environment[$name]

        if ("$name" -match $secretNamePattern -or "$value" -match $secretValuePattern) {
            $masked[$name] = '***REDACTED***'
        }
        else {
            $masked[$name] = $value
        }
    }

    return $masked
}

function Import-PerfTestEnvFile {
    <#
    Load a .env file and find one to load, returning both the values and the path used.

    Why this exists: a journey run needs a login URL, an account and a password, and
    typing those on every invocation is both tedious and a good way to leak the password
    into shell history. A .env file keeps them in one ignored place, and -EnvVars still
    overrides it when a single run needs different values.

    Search order, first hit wins:
      1. -ExplicitPath, when given. A path that does not exist is an ERROR rather than a
         silent fallback, because "I pointed at my file and it used the other one" is
         exactly the confusing outcome this is meant to remove.
      2. Each path in -SearchPaths, in order.

    Format: shell-style KEY=value, one per line.
      * blank lines and lines starting with # are ignored
      * a leading `export ` is accepted, so a file written for a shell still works
      * surrounding single or double quotes are stripped
      * an inline ` # comment` is NOT stripped - a password may legitimately contain
         " # ", and silently truncating one would produce a login failure that looks
         like bad credentials
      * an unrecognised line is an ERROR with its line number. Skipping it silently is
         how a typo becomes a mystery: the value simply never arrives, and the run fails
         somewhere else entirely.

    Returns an object with Path (the file used, or $null) and Values (a hashtable).
    #>
    [CmdletBinding()]
    param(
        [string] $ExplicitPath,
        [string[]] $SearchPaths = @()
    )

    $candidates = @()
    if ($ExplicitPath) {
        if (-not (Test-Path -Path $ExplicitPath -PathType Leaf)) {
            throw "The environment file '$ExplicitPath' does not exist. Pass a real path, or omit -EnvFile to use the default search."
        }
        $candidates = @($ExplicitPath)
    }
    else {
        $candidates = @($SearchPaths | Where-Object { $_ -and (Test-Path -Path $_ -PathType Leaf) })
    }

    if ($candidates.Count -eq 0) {
        return [pscustomobject]@{ Path = $null; Values = @{} }
    }

    $path = (Resolve-Path -Path $candidates[0]).Path
    $values = @{}
    $lineNumber = 0

    foreach ($line in (Get-Content -Path $path)) {
        $lineNumber++
        $entry = "$line".Trim()

        if ($entry -eq '' -or $entry.StartsWith('#')) {
            continue
        }

        if ($entry -match '^export\s+') {
            $entry = $entry.Substring(7).Trim()
        }

        if ($entry -notmatch '^(?<name>[A-Za-z_][A-Za-z0-9_]*)\s*=\s*(?<value>.*)$') {
            throw ("$path line ${lineNumber}: expected KEY=value, but found: $entry")
        }

        $name = $Matches['name']
        $value = $Matches['value'].Trim()

        # Strip one layer of matching quotes.
        if ($value.Length -ge 2) {
            $first = $value.Substring(0, 1)
            $last = $value.Substring($value.Length - 1, 1)
            if (($first -eq '"' -and $last -eq '"') -or ($first -eq "'" -and $last -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
        }

        $values[$name] = $value
    }

    return [pscustomobject]@{ Path = $path; Values = $values }
}

function Get-PerfTestSummaryWindow {
    <#
    Read the run's started_at / ended_at out of a summary.json WITHOUT letting
    PowerShell coerce them into [datetime].

    Why this exists: ConvertFrom-Json silently converts an ISO 8601 string to a
    [datetime]. That value then stringifies in the current culture - on this
    machine "2026-10-01T08:39:30.123Z" became "10/01/2026 08:39:30" - and
    re-parsing a string with no zone designator left makes it LOCAL time. The
    effect was a Grafana link whose time window was shifted by the machine's UTC
    offset (+03:30 here): the run's metrics existed, but the dashboard was
    looking 3.5 hours earlier and every panel read "No data".

    Regex against the raw file keeps exactly the string k6 wrote. Returns $null
    rather than throwing when the fields are absent or unparseable, so callers
    can fall back.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string] $Path
    )

    if (-not (Test-Path $Path -PathType Leaf)) {
        return $null
    }

    $text = Get-Content -Path $Path -Raw
    $startMatch = [regex]::Match($text, '"started_at"\s*:\s*"(?<v>[^"]+)"')
    $endMatch = [regex]::Match($text, '"ended_at"\s*:\s*"(?<v>[^"]+)"')
    if (-not $startMatch.Success -or -not $endMatch.Success) {
        return $null
    }

    $startedAt = [DateTimeOffset]::MinValue
    $endedAt = [DateTimeOffset]::MinValue
    $startOk = [DateTimeOffset]::TryParse($startMatch.Groups['v'].Value, [ref]$startedAt)
    $endOk = [DateTimeOffset]::TryParse($endMatch.Groups['v'].Value, [ref]$endedAt)
    if (-not $startOk -or -not $endOk) {
        return $null
    }

    return [pscustomobject]@{
        StartedAt = $startedAt
        EndedAt   = $endedAt
    }
}

function Get-PerfTestGitRevision {
    [CmdletBinding()]
    param()

    $command = Get-Command git -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $revision = & git -C (Get-PerfTestRepoRoot) rev-parse HEAD 2>&1
        $code = $LASTEXITCODE
        if ($code -ne 0) { return $null }
        return ("$revision").Trim()
    }
    finally {
        $ErrorActionPreference = $previous
    }
}

function Invoke-Kubectl {
    <#
    Run kubectl and return its output as string lines.

    stderr is folded into the returned lines rather than being turned into
    terminating errors: with $ErrorActionPreference = 'Stop', `2>&1` on a native
    command can throw a NativeCommandError before we ever get to inspect the exit
    code, which would hide kubectl's actual message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string[]] $Arguments,
        [switch] $AllowFailure
    )

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        throw "kubectl was not found on PATH. Install it, or use the local docker-compose path (k6/run-test.ps1)."
    }

    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $raw = & kubectl @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previous
    }

    $lines = @($raw | ForEach-Object { "$_" })

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ("kubectl {0} failed with exit code {1}.`n{2}" -f ($Arguments -join ' '), $exitCode, ($lines -join "`n"))
    }

    return , $lines
}

Export-ModuleMember -Function @(
    'Get-PerfTestRepoRoot',
    'Get-PerfTestSummaryMarkers',
    'Write-Utf8NoBom',
    'Get-PerfTestTypes',
    'Resolve-PerfTestScenario',
    'New-PerfTestId',
    'Get-PerfTestHostAddress',
    'Test-PerfTestTcpEndpoint',
    'Get-PerfTestFreeLocalPort',
    'New-PerfTestRunDirectory',
    'Get-K6SummaryJsonFromText',
    'Get-K6SummaryFromText',
    'Get-K6SummaryFromFile',
    'Write-PerfTestMetadata',
    'ConvertTo-PerfTestEnvTable',
    'Protect-PerfTestSecretValues',
    'Import-PerfTestEnvFile',
    'Resolve-PerfTestUsersFile',
    'Read-PerfTestUsersFile',
    'Get-PerfTestSummaryWindow',
    'Get-PerfTestGitRevision',
    'Invoke-Kubectl'
)
