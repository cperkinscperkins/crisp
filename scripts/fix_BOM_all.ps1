$files = Get-ChildItem "src/*.lisp"
foreach ($file in $files) {
    $path = $file.FullName
    $bytes = [System.IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        Write-Host "BOM Detected in $($file.Name). Stripping."
        $newBytes = $bytes[3..($bytes.Length-1)]
        [System.IO.File]::WriteAllBytes($path, $newBytes)
    }
}
Write-Host "Done checking files."