@echo off
set "YARDBIDS_NODE=C:\Users\pll14\.cache\codex-runtimes\codex-primary-runtime\dependencies\node\bin\node.exe"
set "YARDBIDS_APP=%~dp0"

echo Starting YardBids locally...
start "YardBids Local App" /min "%YARDBIDS_NODE%" "%YARDBIDS_APP%server.js"
ping 127.0.0.1 -n 3 >nul
start "" "http://127.0.0.1:3030/"
exit
