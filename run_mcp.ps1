$env:NAVIDROME_URL='https://sopranosnavi.share.zrok.io'
$env:NAVIDROME_USERNAME='Harsh'
$env:NAVIDROME_PASSWORD='u4vTyG7BcBxR-9-'
$process = Start-Process -FilePath 'npx.cmd' -ArgumentList '-y','navidrome-mcp' -PassThru -NoNewWindow -RedirectStandardInput input.txt -RedirectStandardOutput output.txt
