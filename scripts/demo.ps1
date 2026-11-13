$backend = "http://localhost:8000/graphql"
$gateway = "http://localhost:9000/graphql"
$token = "token-goutham"

$attacks = @(
    @{ label = "BOLA read - Martin's order 103";            query = '{ order(id:103){ id total shippingAddress } }' },
    @{ label = "BOLA read - Martin's profile";              query = '{ user(id:3){ id name email } }' },
    @{ label = "Lateral BOLA - owner email via order 103";  query = '{ order(id:103){ owner{ name email } } }' },
    @{ label = "Alias enumeration - all three orders";      query = '{ a:order(id:101){shippingAddress} b:order(id:102){shippingAddress} c:order(id:103){shippingAddress} }' },
    @{ label = "Variable smuggling - id hidden in a var";   query = 'query($id: ID!){ order(id:$id){ shippingAddress } }'; variables = @{ id = "103" } },
    @{ label = "Introspection - download the schema";       query = '{ __schema { queryType { name } } }' },
    @{ label = "Mutation BOLA - rewrite Kumar's address";   query = 'mutation{ updateOrderAddress(id:102, address:"HACKED"){ id shippingAddress } }' }
)

$legit = @(
    @{ label = "Goutham's own order 101";   query = '{ order(id:101){ id total shippingAddress } }' },
    @{ label = "Goutham's own order list";  query = '{ myOrders { id total shippingAddress } }' },
    @{ label = "Goutham's own profile";     query = '{ user(id:1){ id name email } }' }
)

function Send($url, $case) {
    $body = @{ query = $case.query }
    if ($case.variables) { $body.variables = $case.variables }
    try {
        $r = Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" `
                -Headers @{ Authorization = "Bearer $token" } `
                -Body ($body | ConvertTo-Json -Depth 5 -Compress)
    } catch {
        return @{ ok = $false; text = "unreachable" }
    }
    if ($r.PSObject.Properties.Name -contains "errors") {
        return @{ ok = $false; text = $r.errors[0].message }
    }
    return @{ ok = $true; text = ($r.data | ConvertTo-Json -Depth 6 -Compress) }
}

function Clip($s, $n) {
    if ($s.Length -le $n) { return $s }
    return $s.Substring(0, $n) + "..."
}

function CheckUp($url, $name) {
    try {
        Invoke-RestMethod -Uri $url -Method Post -ContentType "application/json" `
            -Headers @{ Authorization = "Bearer $token" } `
            -Body '{"query":"{ me { id } }"}' | Out-Null
        return $true
    } catch {
        Write-Host "$name is not running at $url" -ForegroundColor Red
        return $false
    }
}

Write-Host ""
Write-Host "VulnShop BOLA demo - attacker is Goutham (token-goutham, owns order 101 only)" -ForegroundColor Cyan
Write-Host "Kumar owns order 102. Martin owns order 103." -ForegroundColor Cyan
Write-Host ""

$upBackend = CheckUp $backend "backend"
$upGateway = CheckUp $gateway "gateway"
if (-not ($upBackend -and $upGateway)) {
    Write-Host ""
    Write-Host "Start both first: python app.py in vulnshop, then in gateway." -ForegroundColor Yellow
    exit 1
}

Write-Host "=== ATTACKS (Goutham reaching for other people's data) ===" -ForegroundColor White
Write-Host ""
foreach ($case in $attacks) {
    Write-Host $case.label -ForegroundColor White
    Write-Host ("  query   " + (Clip $case.query 110)) -ForegroundColor DarkGray

    $b = Send $backend $case
    if ($b.ok) { Write-Host ("  :8000   LEAKED   " + (Clip $b.text 110)) -ForegroundColor Red }
    else       { Write-Host ("  :8000   refused  " + (Clip $b.text 110)) -ForegroundColor DarkGray }

    $g = Send $gateway $case
    if ($g.ok) { Write-Host ("  :9000   LEAKED   " + (Clip $g.text 110)) -ForegroundColor Red }
    else       { Write-Host ("  :9000   BLOCKED  " + (Clip $g.text 110)) -ForegroundColor Green }
    Write-Host ""
}

Write-Host "=== LEGITIMATE USE (the gateway must not get in the way) ===" -ForegroundColor White
Write-Host ""
foreach ($case in $legit) {
    Write-Host $case.label -ForegroundColor White
    Write-Host ("  query   " + (Clip $case.query 110)) -ForegroundColor DarkGray
    $g = Send $gateway $case
    if ($g.ok) { Write-Host ("  :9000   ALLOWED  " + (Clip $g.text 110)) -ForegroundColor Green }
    else       { Write-Host ("  :9000   BROKEN   " + (Clip $g.text 110)) -ForegroundColor Red }
    Write-Host ""
}

Write-Host "Restart vulnshop to undo the HACKED address written on port 8000." -ForegroundColor DarkGray
Write-Host ""
