# Dot-sourced by Publish-PcPatch.ps1 and tools\translations\Publish-Locale.ps1:
# turns one build_prefab_patch.py output tree into the two release zips.

# Two zips: everything that carries text (the mandatory half) and the bundles
# that carry nothing but images. The installer downloads the second one only
# after asking, so a player who says no never fetches the art.
# Returns [ordered]@{ prefab_patch = <entry>; prefab_images = <entry or absent> },
# the entries version.json carries (file, size, md5, bundles, hash).
function New-PrefabZips {
    param(
        [Parameter(Mandatory)][string]$PrefabDir,
        [Parameter(Mandatory)][string]$OutDir,
        [Parameter(Mandatory)][string]$TextZipName,
        [Parameter(Mandatory)][string]$ImageZipName,
        # The game build (language bundle asset hash) the tree was built for.
        [Parameter(Mandatory)][string]$Hash
    )
    # No @() around the pipeline: Windows PowerShell 5.1 does not enumerate a
    # JSON array out of ConvertFrom-Json, so @() would wrap it into a 1-element
    # array whose single item is the list. A one-entry manifest parses as a lone
    # object, hence the @() on the variable.
    $manifest = Get-Content -LiteralPath (Join-Path $PrefabDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $manifest = @($manifest)
    if ($manifest.Count -eq 0) { throw 'prefab manifest is empty.' }

    $isImageOnly = { param($e) $e.PSObject.Properties['textures'] -and $e.textures -and
                               -not ($e.PSObject.Properties['changed'] -and $e.changed) }
    $textEntries  = @($manifest | Where-Object { -not (& $isImageOnly $_) })
    $imageEntries = @($manifest | Where-Object { & $isImageOnly $_ })

    $stageRoot  = Join-Path $OutDir "$TextZipName.root"
    $imageStage = Join-Path $OutDir "$ImageZipName.root"
    foreach ($d in @($stageRoot, $imageStage)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    foreach ($pair in @(@($textEntries, $stageRoot), @($imageEntries, $imageStage))) {
        foreach ($e in $pair[0]) {
            $rel = $e.rel -replace '/', '\'
            $dst = Join-Path $pair[1] $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
            Copy-Item -LiteralPath (Join-Path $PrefabDir $rel) -Destination $dst -Force
        }
    }
    # The text manifest, plus the image manifest for -Check (it cannot ask the
    # release what is installed without downloading the image zip).
    $textEntries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stageRoot 'manifest.json') -Encoding UTF8
    $imageEntries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $stageRoot 'manifest-images.json') -Encoding UTF8
    $imageEntries | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $imageStage 'manifest.json') -Encoding UTF8

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $out = [ordered]@{}
    foreach ($z in @(@('prefab_patch', $TextZipName, $stageRoot, $textEntries.Count),
                     @('prefab_images', $ImageZipName, $imageStage, $imageEntries.Count))) {
        if ($z[3] -eq 0) { continue }
        $zip = Join-Path $OutDir $z[1]
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        # No compression: the bundles are already LZ4HC. Packer ordering is not
        # stable, which is why the md5 is recorded per publish.
        [IO.Compression.ZipFile]::CreateFromDirectory($z[2], $zip,
            [IO.Compression.CompressionLevel]::NoCompression, $false)
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $fs = [System.IO.File]::OpenRead($zip)
        try { $sum = ($md5.ComputeHash($fs) | ForEach-Object { $_.ToString('x2') }) -join '' }
        finally { $fs.Close(); $md5.Dispose() }
        $out[$z[0]] = [ordered]@{
            file    = $z[1]
            size    = (Get-Item -LiteralPath $zip).Length
            md5     = $sum
            bundles = $z[3]
            hash    = $Hash
        }
        Write-Host "staged $($z[1]) : $($z[3]) bundles, $([math]::Round((Get-Item -LiteralPath $zip).Length / 1MB, 1)) MB"
        Remove-Item -LiteralPath $z[2] -Recurse -Force
    }
    if (-not $out.Contains('prefab_patch')) { throw 'prefab build has no text bundles.' }
    return $out
}
