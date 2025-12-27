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
REM 1. Specs Runner (Internal & External)
REM ---------------------------------------------------

echo.
echo --- Running Internal Runner ---
sbcl --script tests/run-specs.lisp
if errorlevel 1 (
    echo [FAILED] Internal Runner failed.
    exit /b 1
)

echo.
echo --- Running External Runner (Binary) ---
sbcl --script tests/run-specs.lisp --use-binary
if errorlevel 1 (
    echo [FAILED] External Runner failed.
    exit /b 1
)

echo.
echo --- Running External Runner (Debug) ---
sbcl --script tests/run-specs.lisp --use-binary --debug
if errorlevel 1 (
    echo [FAILED] External Runner ^(Debug^) failed.
    exit /b 1
)

REM ---------------------------------------------------
REM 3. Failure Tests (Expected to Fail)
REM ---------------------------------------------------
echo.
echo [3/3] Running Failure Tests...


echo --- Running Negative Specs (Unified Runner) ---
sbcl --script tests/run-error-specs.lisp
if errorlevel 1 (
    echo [FAILED] Negative Specs Runner failed.
    exit /b 1
)

echo.
echo =================================================
echo            All Tests Passed!
echo =================================================
exit /b 0