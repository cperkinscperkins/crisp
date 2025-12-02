@echo off
setlocal enabledelayedexpansion

REM This script runs all .crisp test files located in the tests/ directory
REM using the crisp-compile executable. It runs each test multiple times
REM with different flags to simulate the CI environment.

REM Ensure the executable exists before we start.
if not exist "bin\crisp-compile.exe" (
    echo Error: Compiler executable not found at bin\crisp-compile.exe
    echo Please build the project first using 'sbcl --load build/build.lisp'.
    exit /b 1
)

echo =================================================
echo            Running Crisp E2E Tests
echo =================================================

REM ---------------------------------------------------
REM 1. Success Tests (Default and Debug)
REM ---------------------------------------------------
echo.
echo [1/3] Running Success Tests...

for %%f in (tests\*.crisp) do (
    echo.
    echo --- Running test: %%f ---
    bin\crisp-compile.exe %%f
    if errorlevel 1 (
        echo [FAILED] Test failed: %%f
        exit /b 1
    ) else (
        echo [PASSED]
    )

    echo --- Running test: %%f --debug ---
    bin\crisp-compile.exe %%f --debug
    if errorlevel 1 (
        echo [FAILED] Test failed: %%f --debug
        exit /b 1
    ) else (
        echo [PASSED]
    )
)

REM ---------------------------------------------------
REM 2. Single-Pass Tests (Specific Files)
REM ---------------------------------------------------
echo.
echo [2/3] Running Single-Pass Tests...

set SINGLE_PASS_TESTS=tests\def-function_primitive.crisp tests\scratch-cell.crisp

for %%f in (%SINGLE_PASS_TESTS%) do (
    echo.
    echo --- Running test: %%f --single-pass ---
    bin\crisp-compile.exe %%f --single-pass
    if errorlevel 1 (
        echo [FAILED] Test failed: %%f --single-pass
        exit /b 1
    ) else (
        echo [PASSED]
    )

    echo --- Running test: %%f --debug --single-pass ---
    bin\crisp-compile.exe %%f --debug --single-pass
    if errorlevel 1 (
        echo [FAILED] Test failed: %%f --debug --single-pass
        exit /b 1
    ) else (
        echo [PASSED]
    )
)

REM ---------------------------------------------------
REM 3. Failure Tests (Expected to Fail)
REM ---------------------------------------------------
echo.
echo [3/3] Running Failure Tests...

for %%f in (tests\errors\*.crisp) do (
    echo.
    echo --- Running failure test: %%f ---
    bin\crisp-compile.exe %%f >nul 2>&1
    if errorlevel 1 (
        echo [PASSED] ^(Expected failure occurred^)
    ) else (
        echo [FAILED] Test succeeded but should have failed: %%f
        exit /b 1
    )
)

echo.
echo =================================================
echo            All Tests Passed!
echo =================================================
exit /b 0