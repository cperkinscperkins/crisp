@echo off
title Lisp Dev MCP Server
echo Setting up environment (OpenSSL from Git)...
set "PATH=C:\Program Files\Git\mingw64\bin;%PATH%"
echo Starting SBCL with Lisp Dev MCP...
sbcl --noinform --load start-mcp.lisp
pause
